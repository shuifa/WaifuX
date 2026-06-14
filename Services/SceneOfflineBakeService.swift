import AppKit
import AVFoundation
import Foundation
import Kingfisher

enum SceneOfflineBakeError: LocalizedError {
    case cliNotFound
    case ineligible
    case contentRootMissing
    case insufficientMemory
    case concurrentBakeInProgress
    case bakeProcessFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound: return "未找到 wallpaper-wgpu"
        case .ineligible: return "当前 Scene 不适合离线烘焙（资格不足）"
        case .contentRootMissing: return "内容目录不存在，请重新下载"
        case .insufficientMemory: return LocalizationService.shared.t("sceneBake.error.insufficientMemory.bake")
        case .concurrentBakeInProgress: return LocalizationService.shared.t("sceneBake.error.concurrent")
        case .bakeProcessFailed(let msg): return msg
        }
    }
}

enum SceneBakeRenderer: String, CaseIterable, Codable, Hashable, Sendable {
    case wallpaperWgpu
    case legacyCLI

    var displayName: String {
        switch self {
        case .wallpaperWgpu: return "1. wallpaper-wgpu"
        case .legacyCLI: return "2. wallpaperengine-cli"
        }
    }
}

extension Notification.Name {
    /// Scene 离线烘焙完成（成功或失败）。`object` 为 `SceneBakeArtifact?`，失败时为 `nil`。
    static let sceneOfflineBakeDidComplete = Notification.Name("sceneOfflineBakeDidComplete")
    /// 烘焙视频抽帧封面已生成。`object` 为 `String`（itemID），`userInfo["thumbnailURL"]` 为 `URL`。
    static let sceneOfflineBakeThumbnailDidUpdate = Notification.Name("sceneOfflineBakeThumbnailDidUpdate")
    /// 烘焙进度更新。`object` 为 `String`（itemID），`userInfo["progress"]` 为 `Double`（0.0 ~ 1.0）。
    static let sceneOfflineBakeProgressDidUpdate = Notification.Name("sceneOfflineBakeProgressDidUpdate")
}

@discardableResult
@MainActor
func regenerateSceneBakePosterAndNotify(itemID: String, videoURL: URL) async -> URL? {
    guard SceneOfflineBakeService.isUsableBakedVideo(at: videoURL) else { return nil }
    guard let posterURL = await VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
        forLocalVideo: videoURL,
        itemID: itemID,
        forceRegenerate: true
    ) else {
        return nil
    }
    // 清除 Kingfisher 对该 poster URL 的缓存，确保下次 KFImage 加载时读取磁盘上的新文件
    try? await ImageCache.default.removeImage(forKey: posterURL.cacheKey)
    // KFImage 使用了 DownsamplingImageProcessor(size: 512x512)，处理器会生成不同的缓存 key
    // （格式：originalKey@processorIdentifier），必须一并清除，否则旧的降采样版本仍被命中
    let processor = DownsamplingImageProcessor(size: CGSize(width: 512, height: 512))
    try? await ImageCache.default.removeImage(forKey: posterURL.cacheKey, processorIdentifier: processor.identifier)
    print("[BakeService] ✅ 已清除 Kingfisher 缓存: \(posterURL.cacheKey)")
    NotificationCenter.default.post(
        name: .sceneOfflineBakeThumbnailDidUpdate,
        object: itemID,
        userInfo: ["thumbnailURL": posterURL]
    )
    return posterURL
}

/// 全局只允许一个 `wallpaper-wgpu bake` 子进程，避免重叠渲染导致内存成倍上涨。
private actor SceneOfflineBakeConcurrencyGate {
    static let shared = SceneOfflineBakeConcurrencyGate()
    private var busy = false
    private var busySince: Date?

    func tryEnter() -> Bool {
        // 安全重置：如果门控卡死超过 10 分钟，自动重置
        if busy, let since = busySince, Date().timeIntervalSince(since) > 600 {
            print("[SceneOfflineBakeConcurrencyGate] ⚠️ 门控卡死超过 10 分钟，自动重置")
            busy = false
            busySince = nil
        }
        if busy { return false }
        busy = true
        busySince = Date()
        return true
    }

    func leave() {
        busy = false
        busySince = nil
    }
}

@MainActor
private final class ScenePreviewProcessController {
    static let shared = ScenePreviewProcessController()
    private var process: Process?
    private var renderer: SceneBakeRenderer?

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
        self.process = nil
        self.renderer = nil
    }

    func launch(executableURL: URL, arguments: [String], renderer: SceneBakeRenderer) throws {
        stop()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = SceneOfflineBakeService.rendererLaunchEnvironment(for: executableURL)
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.process?.processIdentifier == process.processIdentifier {
                    self.process = nil
                    self.renderer = nil
                }
            }
        }
        try process.run()
        self.process = process
        self.renderer = renderer
    }
}

/// 将 Workshop Scene 预渲染为循环 MP4，并写入下载记录。
enum SceneOfflineBakeService {
    private struct BakedVideoInspection {
        let duration: TimeInterval
        let width: Int
        let height: Int
    }

    private static func displayIDs(for screens: [NSScreen]?) -> [UInt32] {
        let targetScreens = (screens?.isEmpty == false) ? screens! : NSScreen.screens
        return targetScreens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
    }

    private static func usableArtifact(from record: MediaDownloadRecord?) -> SceneBakeArtifact? {
        guard let record,
              let artifact = record.sceneBakeArtifact,
              artifact.analysisId == record.sceneBakeEligibility?.analysisId,
              isUsableBakedVideo(at: URL(fileURLWithPath: artifact.videoPath)) else {
            return nil
        }
        return artifact
    }

    @MainActor
    private static func downloadedRecord(forResolvedContentRoot contentRoot: URL) -> MediaDownloadRecord? {
        let resolvedPath = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: contentRoot).path
        if let exact = MediaLibraryService.shared.downloadRecord(forLocalFilePath: resolvedPath) {
            return exact
        }
        return MediaLibraryService.shared.downloadedItems.first { record in
            WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: URL(fileURLWithPath: record.localFilePath)).path == resolvedPath
        }
    }

    /// 实时渲染桌面后配套生成离线 MP4。
    /// 该 MP4 不会反向替换桌面实时渲染；如果动态锁屏开启，则烘焙完成后推送给对应显示器实例。
    @MainActor
    static func scheduleRealtimeCompanionBake(path: String, targetScreens: [NSScreen]? = nil, reason: String) {
        guard #available(macOS 26.0, *) else { return }
        let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: URL(fileURLWithPath: path))
        guard SceneBakeEligibilityAnalyzer.sceneContentRootIfEligibleForAnalysis(localFileURL: contentRoot) != nil else {
            print("[SceneOfflineBake] realtime companion bake skipped (\(reason)): not a scene project \(contentRoot.path)")
            return
        }

        let displayIDs = displayIDs(for: targetScreens)

        Task(priority: .utility) {
            do {
                let record = await MainActor.run {
                    downloadedRecord(forResolvedContentRoot: contentRoot)
                }

                if let artifact = usableArtifact(from: record) {
                    await syncRealtimeBakeToLockScreen(artifact: artifact, itemID: record?.item.id, displayIDs: displayIDs, reason: reason)
                    print("[SceneOfflineBake] realtime companion bake cache hit (\(reason)): \(artifact.videoPath)")
                    return
                }

                let eligibility: SceneBakeEligibilitySnapshot
                if let existing = record?.sceneBakeEligibility,
                   existing.contentRootPath == contentRoot.path {
                    eligibility = existing
                } else {
                    guard SystemMemoryPressure.hasRoomForSceneEligibilityAnalysis() else {
                        print("[SceneOfflineBake] realtime companion bake skipped (\(reason)): insufficient memory for analysis")
                        return
                    }
                    eligibility = try await Task.detached(priority: .utility) {
                        try SceneBakeEligibilityAnalyzer.analyze(contentRoot: contentRoot, intent: .desktopLoop, strict: false)
                    }.value
                    if let itemID = record?.item.id {
                        await MainActor.run {
                            MediaLibraryService.shared.attachSceneBakeEligibility(
                                itemID: itemID,
                                snapshot: eligibility,
                                triggerAutoBake: false
                            )
                        }
                    }
                }

                let itemID = record?.item.id
                let cacheItemID = itemID ?? stableOrphanCacheItemID(contentRootPath: contentRoot.path)
                let artifact = try await bake(
                    eligibility: eligibility,
                    contentRoot: contentRoot,
                    cacheItemID: cacheItemID,
                    renderer: .wallpaperWgpu,
                    persistArtifactToItemID: itemID
                )
                print("[SceneOfflineBake] realtime companion bake finished (\(reason)): \(artifact.videoPath)")
                await syncRealtimeBakeToLockScreen(artifact: artifact, itemID: itemID, displayIDs: displayIDs, reason: reason)
            } catch SceneOfflineBakeError.concurrentBakeInProgress {
                print("[SceneOfflineBake] realtime companion bake skipped (\(reason)): another bake is running")
            } catch {
                print("[SceneOfflineBake] realtime companion bake failed (\(reason)): \(error.localizedDescription)")
            }
        }
    }

    @available(macOS 26.0, *)
    @MainActor
    private static func syncRealtimeBakeToLockScreen(
        artifact: SceneBakeArtifact,
        itemID: String?,
        displayIDs: [UInt32],
        reason: String
    ) async {
        guard VideoWallpaperManager.shared.isLockScreenEnabled, !displayIDs.isEmpty else { return }
        let videoURL = URL(fileURLWithPath: artifact.videoPath)
        guard isUsableBakedVideo(at: videoURL) else { return }
        let videoID = itemID ?? URL(fileURLWithPath: artifact.videoPath).deletingPathExtension().lastPathComponent
        await LockScreenWallpaperService.shared.switchActiveInstancesToLocalDecode(
            videoURL: videoURL,
            videoID: videoID,
            displayIDs: displayIDs
        )
        print("[SceneOfflineBake] realtime companion bake synced lock screen (\(reason)): display=\(displayIDs) video=\(videoID)")
    }

    @MainActor
    static func isRendererAvailable(_ renderer: SceneBakeRenderer) -> Bool {
        switch renderer {
        case .wallpaperWgpu:
            return WallpaperEngineXBridge.resolvedCLIExecutableURL() != nil
        case .legacyCLI:
            return resolvedLegacyCLIExecutableURL() != nil
        }
    }

    @MainActor
    static func stopPreview() {
        ScenePreviewProcessController.shared.stop()
    }

    @MainActor
    static func preview(record: MediaDownloadRecord, renderer: SceneBakeRenderer) throws {
        guard let eligibility = record.sceneBakeEligibility else {
            throw SceneOfflineBakeError.ineligible
        }
        let contentRoot = URL(fileURLWithPath: eligibility.contentRootPath)
        try preview(
            eligibility: eligibility,
            contentRoot: contentRoot,
            renderer: renderer
        )
    }

    @MainActor
    static func preview(
        eligibility: SceneBakeEligibilitySnapshot,
        contentRoot: URL,
        renderer: SceneBakeRenderer
    ) throws {
        guard FileManager.default.fileExists(atPath: contentRoot.path) else {
            throw SceneOfflineBakeError.contentRootMissing
        }

        switch renderer {
        case .wallpaperWgpu:
            guard let cli = WallpaperEngineXBridge.resolvedCLIExecutableURL() else {
                throw SceneOfflineBakeError.cliNotFound
            }
            // 预览不传 `--wallpaper` / `--background`：保留一个普通可见窗口供用户查看，
            // 不要把窗口贴成桌面壁纸层级（壁纸层级会被其他窗口遮住，且鼠标事件全部穿透）。
            var args = [contentRoot.path]
            if let assets = WallpaperEngineEmbeddedAssets.materializedAssetsRootIfPresent(),
               !assets.isEmpty {
                args += ["--assets", assets]
            }
            try ScenePreviewProcessController.shared.launch(
                executableURL: cli,
                arguments: args,
                renderer: renderer
            )
        case .legacyCLI:
            guard let cli = resolvedLegacyCLIExecutableURL() else {
                throw SceneOfflineBakeError.bakeProcessFailed("未找到 wallpaperengine-cli，无法预览渲染器 2")
            }
            let screen = NSScreen.main?.frame ?? .init(x: 0, y: 0, width: 1920, height: 1080)
            let width = max(64, Int(screen.width))
            let height = max(64, Int(screen.height))
            try ScenePreviewProcessController.shared.launch(
                executableURL: cli,
                arguments: [
                    "preview",
                    contentRoot.path,
                    String(width),
                    String(height)
                ],
                renderer: renderer
            )
        }
    }

    /// 缓存文件路径：`analysisId + 分辨率 + fps + 时长`（根目录为 `DownloadPathManager.sceneBakesFolderURL`）
    private static func cacheVideoURL(
        baseDir: URL,
        itemID: String,
        analysisId: UUID,
        renderer: SceneBakeRenderer,
        width: Int,
        height: Int,
        fps: Int,
        durationSeconds: Double
    ) -> URL {
        let safeID = itemID.replacingOccurrences(of: "/", with: "_")
        let dir = baseDir.appendingPathComponent(safeID, isDirectory: true)
        let name =
            "\(analysisId.uuidString)_\(renderer.rawValue)_\(width)x\(height)_\(fps)fps_\(Int(durationSeconds))s.mp4"
        return dir.appendingPathComponent(name)
    }

    static func rendererLaunchEnvironment(for executableURL: URL) -> [String: String] {
        let rendererDirectory = executableURL.deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        let searchPaths = [
            rendererDirectory.path,
            rendererDirectory.deletingLastPathComponent().path,
            env["PATH"] ?? ""
        ].filter { !$0.isEmpty }
        env["PATH"] = searchPaths.joined(separator: ":")

        let libraryPaths = [
            rendererDirectory.appendingPathComponent("lib").path,
            rendererDirectory.deletingLastPathComponent().appendingPathComponent("lib").path,
            rendererDirectory.appendingPathComponent("Resources").appendingPathComponent("lib").path,
            rendererDirectory.deletingLastPathComponent().appendingPathComponent("Resources/lib").path,
            env["DYLD_LIBRARY_PATH"] ?? ""
        ].filter { !$0.isEmpty }
        env["DYLD_LIBRARY_PATH"] = libraryPaths.joined(separator: ":")
        return env
    }

    /// 无媒体库记录时（例如仅能从 Steam 目录解析到工程）用于缓存目录名的稳定 ID。
    static func stableOrphanCacheItemID(contentRootPath: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for b in contentRootPath.utf8 {
            hash ^= UInt64(b)
            hash &*= 1099511628211
        }
        return "orphan_\(hash)"
    }

    /// 与资格快照配套；`cacheItemID` 通常等于 `MediaItem.id`，无记录时用 `stableOrphanCacheItemID`。
    /// - Parameter persistArtifactToItemID: 非 nil 时将成品写回对应下载记录。
    static func bake(
        eligibility: SceneBakeEligibilitySnapshot,
        contentRoot: URL,
        cacheItemID: String,
        durationSeconds: Double = 15,
        fps: Int32 = 30,
        renderer: SceneBakeRenderer = .wallpaperWgpu,
        persistArtifactToItemID: String? = nil,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> SceneBakeArtifact {
        // 并发门控：防止多个烘焙同时运行
        let entered = await SceneOfflineBakeConcurrencyGate.shared.tryEnter()
        guard entered else {
            throw SceneOfflineBakeError.concurrentBakeInProgress
        }
        do {
            let result = try await bakeCore(
                eligibility: eligibility,
                contentRoot: contentRoot,
                cacheItemID: cacheItemID,
                durationSeconds: durationSeconds,
                fps: fps,
                renderer: renderer,
                persistArtifactToItemID: persistArtifactToItemID,
                progress: progress
            )
            await SceneOfflineBakeConcurrencyGate.shared.leave()
            await MainActor.run {
                NotificationCenter.default.post(name: .sceneOfflineBakeDidComplete, object: result)
            }
            return result
        } catch {
            await SceneOfflineBakeConcurrencyGate.shared.leave()
            await MainActor.run {
                NotificationCenter.default.post(name: .sceneOfflineBakeDidComplete, object: nil)
            }
            throw error
        }
    }

    private static func bakeCore(
        eligibility: SceneBakeEligibilitySnapshot,
        contentRoot: URL,
        cacheItemID: String,
        durationSeconds: Double,
        fps: Int32,
        renderer: SceneBakeRenderer,
        persistArtifactToItemID: String?,
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> SceneBakeArtifact {
        guard FileManager.default.fileExists(atPath: contentRoot.path) else {
            throw SceneOfflineBakeError.contentRootMissing
        }
        guard SystemMemoryPressure.hasRoomForSceneOfflineBake() else {
            throw SceneOfflineBakeError.insufficientMemory
        }

        let mainDisplaySize = mainDisplayPixelSize()
        let w = max(64, mainDisplaySize.width)
        let h = max(64, mainDisplaySize.height)
        let evenW = (w / 2) * 2
        let evenH = (h / 2) * 2

        let sceneBakesRoot = await MainActor.run {
            DownloadPathManager.shared.sceneBakesFolderURL
        }
        let cacheDurationSeconds = renderer == .legacyCLI ? 0 : durationSeconds
        let outURL = cacheVideoURL(
            baseDir: sceneBakesRoot,
            itemID: cacheItemID,
            analysisId: eligibility.analysisId,
            renderer: renderer,
            width: evenW,
            height: evenH,
            fps: Int(fps),
            durationSeconds: cacheDurationSeconds
        )

        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let cachedInspection: BakedVideoInspection? = await {
            switch renderer {
            case .wallpaperWgpu:
                return await inspectBakedVideo(at: outURL, expectedWidth: evenW, expectedHeight: evenH)
            case .legacyCLI:
                return await inspectBakedVideo(at: outURL)
            }
        }()
        if let cachedInspection,
           let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path) {
            let artifact = SceneBakeArtifact(
                analysisId: eligibility.analysisId,
                videoPath: outURL.path,
                width: cachedInspection.width,
                height: cachedInspection.height,
                fps: Int(fps),
                durationSeconds: renderer == .legacyCLI ? cachedInspection.duration : durationSeconds,
                bakedAt: (attrs[.creationDate] as? Date) ?? .now,
                renderer: renderer
            )
            if let itemID = persistArtifactToItemID {
                await MainActor.run {
                    MediaLibraryService.shared.attachSceneBakeArtifact(
                        itemID: itemID,
                        artifact: artifact,
                        regeneratePoster: false
                    )
                }
                await regenerateSceneBakePosterAndNotify(
                    itemID: itemID,
                    videoURL: URL(fileURLWithPath: artifact.videoPath)
                )
            }
            return artifact
        }
        if FileManager.default.fileExists(atPath: outURL.path) {
            print("[SceneOfflineBake] removing invalid cached MP4: \(outURL.path)")
            try? FileManager.default.removeItem(at: outURL)
        }

        if renderer == .legacyCLI {
            await MainActor.run {
                WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()
            }
            // 与 stop 子进程错开
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        let artifact: SceneBakeArtifact
        switch renderer {
        case .wallpaperWgpu:
            artifact = try await bakeWithWallpaperWgpu(
                contentRoot: contentRoot,
                outURL: outURL,
                eligibility: eligibility,
                width: evenW,
                height: evenH,
                fps: fps,
                durationSeconds: durationSeconds,
                progress: progress
            )
        case .legacyCLI:
            // legacyCLI 通过 stderr 的 BAKE_PROGRESS: 行上报真实进度
            artifact = try await bakeWithLegacyCLI(
                contentRoot: contentRoot,
                outURL: outURL,
                eligibility: eligibility,
                width: evenW,
                height: evenH,
                fps: fps,
                progress: progress
            )
            await MainActor.run { progress?(1.0) }
        }
        if let itemID = persistArtifactToItemID {
            await MainActor.run {
                MediaLibraryService.shared.attachSceneBakeArtifact(
                    itemID: itemID,
                    artifact: artifact,
                    regeneratePoster: false
                )
            }
            await regenerateSceneBakePosterAndNotify(
                itemID: itemID,
                videoURL: URL(fileURLWithPath: artifact.videoPath)
            )
        }

        return artifact
    }

    private static func bakeWithWallpaperWgpu(
        contentRoot: URL,
        outURL: URL,
        eligibility: SceneBakeEligibilitySnapshot,
        width: Int,
        height: Int,
        fps: Int32,
        durationSeconds: Double,
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> SceneBakeArtifact {
        // 使用 wallpaper-wgpu bake 子命令（GPU readback 直接编码，不需要屏幕录制）
        guard let wgpuBinary = WallpaperEngineXBridge.resolvedCLIExecutableURL() else {
            throw SceneOfflineBakeError.cliNotFound
        }

        let tempURL = outURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).tmp.mp4")
        try? FileManager.default.removeItem(at: tempURL)

        // wallpaper-wgpu bake <path> --size WxH --fps N --duration S --out <path> [--assets <path>] [--clean]
        var args: [String] = [
            "bake",
            contentRoot.path,
            "--size", "\(width)x\(height)",
            "--fps", String(fps),
            "--clean",
            "--out", tempURL.path,
        ]

        // assets 路径
        if let assets = WallpaperEngineEmbeddedAssets.materializedAssetsRootIfPresent(), !assets.isEmpty {
            args += ["--assets", assets]
        }

        // 自动检测周期时不需要传 --duration，让 bake 自己检测
        if durationSeconds > 0 {
            args += ["--duration", String(Int(durationSeconds))]
        }

        print("[SceneOfflineBake] 启动 wallpaper-wgpu bake: \(wgpuBinary.lastPathComponent) \(args.joined(separator: " "))")

        let process = Process()
        process.executableURL = wgpuBinary
        process.arguments = args
        process.environment = SceneOfflineBakeService.rendererLaunchEnvironment(for: wgpuBinary)

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()

        // 监控 stderr 中的进度信息
        // 格式: \r[bake] {message} [{progress * 100:.0}%]
        let stderrHandle = stderrPipe.fileHandleForReading
        let progressTask = Task.detached(priority: .utility) {
            let pattern = try? NSRegularExpression(pattern: #"\[(\d+\.?\d*)%\]"#)
            var buffer = ""
            while !Task.isCancelled {
                let data = stderrHandle.availableData
                if data.isEmpty { break }
                if let chunk = String(data: data, encoding: .utf8) {
                    buffer += chunk
                    let lines = buffer.components(separatedBy: "\r")
                    buffer = lines.last ?? ""
                    for line in lines.dropLast() {
                        if let match = pattern?.firstMatch(
                            in: line,
                            range: NSRange(location: 0, length: line.utf16.count)
                        ), let range = Range(match.range(at: 1), in: line),
                           let pct = Double(line[range]) {
                            await progress?(pct / 100.0)
                        }
                    }
                }
            }
            // 处理缓冲区中剩余内容
            if !buffer.isEmpty, let match = pattern?.firstMatch(
                in: buffer,
                range: NSRange(location: 0, length: buffer.utf16.count)
            ), let range = Range(match.range(at: 1), in: buffer),
               let pct = Double(buffer[range]) {
                await progress?(pct / 100.0)
            }
        }

        // 用轮询替代 waitUntilExit，避免阻塞 cooperative thread pool
        while process.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        progressTask.cancel()

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw SceneOfflineBakeError.bakeProcessFailed("wallpaper-wgpu bake 执行失败 (exit=\(process.terminationStatus))")
        }

        guard await inspectBakedVideo(at: tempURL, expectedWidth: width, expectedHeight: height) != nil else {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(at: outURL)
            throw SceneOfflineBakeError.bakeProcessFailed("bake 完成后未找到输出文件")
        }
        try? FileManager.default.removeItem(at: outURL)
        try FileManager.default.moveItem(at: tempURL, to: outURL)

        await MainActor.run { progress?(1.0) }

        return SceneBakeArtifact(
            analysisId: eligibility.analysisId,
            videoPath: outURL.path,
            width: width,
            height: height,
            fps: Int(fps),
            durationSeconds: durationSeconds,
            bakedAt: .now,
            renderer: .wallpaperWgpu
        )
    }

    private static func bakeWithLegacyCLI(
        contentRoot: URL,
        outURL: URL,
        eligibility: SceneBakeEligibilitySnapshot,
        width: Int,
        height: Int,
        fps: Int32,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> SceneBakeArtifact {
        guard let cli = resolvedLegacyCLIExecutableURL() else {
            throw SceneOfflineBakeError.bakeProcessFailed("未找到 wallpaperengine-cli，无法使用渲染器 2 烘焙")
        }

        let task = Process()
        task.executableURL = cli
        task.arguments = [
            "bake",
            contentRoot.path,
            outURL.path,
            String(width),
            String(height),
            String(fps),
            "--no-dynamic-text"
        ]
        var env = ProcessInfo.processInfo.environment
        env["LSUIElement"] = "1"
        let execDir = cli.deletingLastPathComponent()
        let dylibCandidates = [
            execDir.path,
            execDir.appendingPathComponent("lib").path,
            execDir.appendingPathComponent("Resources").path,
            execDir.appendingPathComponent("Resources/lib").path,
            execDir.deletingLastPathComponent().appendingPathComponent("Resources/lib").path,
            execDir.deletingLastPathComponent().appendingPathComponent("Frameworks").path
        ]
        var libPaths: [String] = []
        if let existing = env["DYLD_LIBRARY_PATH"], !existing.isEmpty {
            libPaths.append(existing)
        }
        for candidate in dylibCandidates {
            let p = candidate + "/liblinux-wallpaperengine-renderer.dylib"
            if FileManager.default.fileExists(atPath: p) {
                libPaths.append(candidate)
            }
        }
        if !libPaths.isEmpty {
            env["DYLD_LIBRARY_PATH"] = libPaths.joined(separator: ":")
        }
        task.environment = env

        // 收集 stdout/stderr，同时从 stderr 解析 BAKE_PROGRESS: 行获取真实进度
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        // 使用 @unchecked Sendable 包装器来安全地在并发闭包中共享可变数据
        final class MutableBox<T>: @unchecked Sendable {
            var value: T
            init(_ value: T) { self.value = value }
        }

        let stderrData = MutableBox(Data())
        let stdoutData = MutableBox(Data())
        let latestProgress = MutableBox(0.0)

        // 读取 stdout，捕获 DYNAMIC_TEXTS: 行
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutData.value.append(data)
        }

        // BAKE_PROGRESS: 行解析：wallpaperengine-cli Swift 版会从 dylib 转发真实烘焙进度。
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrData.value.append(data)
            if let chunk = String(data: data, encoding: .utf8) {
                for line in chunk.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("BAKE_PROGRESS:") {
                        let valueStr = trimmed.dropFirst(14)
                        if let value = Double(valueStr) {
                            let clamped = min(max(value, 0.0), 0.99)
                            let monotonic = max(latestProgress.value, clamped)
                            guard monotonic > latestProgress.value else { continue }
                            latestProgress.value = monotonic
                            Task { @MainActor in
                                progress?(monotonic)
                            }
                        }
                    }
                }
            }
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SceneBakeArtifact, Error>) in
            task.terminationHandler = { process in
                errPipe.fileHandleForReading.readabilityHandler = nil
                outPipe.fileHandleForReading.readabilityHandler = nil

                let termStatus = process.terminationStatus
                let termReason: Process.TerminationReason
                if #available(macOS 10.15, *) {
                    termReason = process.terminationReason
                } else {
                    termReason = .exit
                }

                // 组装完整输出字符串（不含 BAKE_PROGRESS 行）
                let stderrString = String(data: stderrData.value, encoding: .utf8) ?? ""
                let cleanStderr = stderrString
                    .components(separatedBy: "\n")
                    .filter { !$0.hasPrefix("BAKE_PROGRESS:") }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if termStatus == 0 {
                    // 等待文件落盘
                    for attempt in 0 ..< 15 {
                        if FileManager.default.fileExists(atPath: outURL.path),
                           let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path),
                           let sz = attrs[.size] as? NSNumber, sz.intValue > 10_000 {
                            break
                        }
                        if attempt == 14 { break }
                        Thread.sleep(forTimeInterval: 0.08)
                    }

                    let bakedInspection = inspectBakedVideoSync(at: outURL)
                    if let bakedInspection {
                        // wallpaperengine-cli 内部已直接将动态文本 JSON 写入 sidecar 文件
                        continuation.resume(returning: SceneBakeArtifact(
                            analysisId: eligibility.analysisId,
                            videoPath: outURL.path,
                            width: bakedInspection.width,
                            height: bakedInspection.height,
                            fps: Int(fps),
                            durationSeconds: bakedInspection.duration,
                            bakedAt: .now,
                            renderer: .legacyCLI
                        ))
                    } else {
                        continuation.resume(throwing: SceneOfflineBakeError.bakeProcessFailed(
                            cleanStderr.isEmpty ? "CLI 退出码 0 但输出文件不可播放" : cleanStderr
                        ))
                    }
                } else {
                    var hint = ""
                    if termReason == .uncaughtSignal, termStatus == 9 {
                        hint = "（退出码 9 多为 SIGKILL：内存压力或系统终止子进程；可关闭其它占用 GPU/内存的应用后重试）"
                    } else if termStatus == 9 {
                        hint = "（若 stderr 无明确错误，退出码 9 常为 SIGKILL）"
                    }
                    let base = cleanStderr.isEmpty ? "wallpaperengine-cli bake 退出码 \(termStatus)\(hint)" : cleanStderr + (hint.isEmpty ? "" : "\n\(hint)")
                    try? FileManager.default.removeItem(at: outURL)
                    continuation.resume(throwing: SceneOfflineBakeError.bakeProcessFailed(base))
                }
            }

            do {
                try task.run()
            } catch {
                continuation.resume(throwing: SceneOfflineBakeError.bakeProcessFailed("启动 CLI 失败: \(error.localizedDescription)"))
            }
        }
    }

    static func resolvedLegacyCLIExecutableURL() -> URL? {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.url(forResource: "wallpaperengine-cli", withExtension: nil),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/wallpaperengine-cli"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Resources/wallpaperengine-cli"),
            Bundle.main.resourceURL?.appendingPathComponent("wallpaperengine-cli"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("wallpaperengine-cli"),
            // linux-wallpaperengine-cli（C++ 独立版）支持 BAKE_PROGRESS: 原生进度输出
            URL(fileURLWithPath: "/Volumes/mac/CodeLibrary/Claude/WallHaven/linux-wallpaperengine-cli"),
            URL(fileURLWithPath: "/Volumes/mac/CodeLibrary/Claude/WallHaven/Resources/linux-wallpaperengine-cli"),
            URL(fileURLWithPath: "/Volumes/mac/CodeLibrary/Claude/WallHaven/wallpaperengine-cli"),
            URL(fileURLWithPath: "/Volumes/mac/CodeLibrary/Claude/WallHaven/Resources/wallpaperengine-cli")
        ].compactMap { $0 }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) || fm.fileExists(atPath: $0.path) }
    }

    /// 检查是否有缓存（不触发实际烘焙）
    static func hasCachedArtifact(record: MediaDownloadRecord, renderer: SceneBakeRenderer? = nil) -> Bool {
        guard let art = record.sceneBakeArtifact,
              art.analysisId == record.sceneBakeEligibility?.analysisId,
              isUsableBakedVideo(at: URL(fileURLWithPath: art.videoPath)) else { return false }
        if let renderer {
            return art.renderer == renderer
        }
        return true
    }

    /// 与 `MediaDownloadRecord.sceneBakeEligibility` 配套；默认主屏逻辑分辨率 × scale、8s、30fps。
    static func bake(
        record: MediaDownloadRecord,
        durationSeconds: Double = 15,
        fps: Int32 = 30,
        renderer: SceneBakeRenderer = .wallpaperWgpu,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> SceneBakeArtifact {
        guard let eligibility = record.sceneBakeEligibility else {
            throw SceneOfflineBakeError.ineligible
        }
        let contentRoot = URL(fileURLWithPath: eligibility.contentRootPath)
        return try await bake(
            eligibility: eligibility,
            contentRoot: contentRoot,
            cacheItemID: record.id,
            durationSeconds: durationSeconds,
            fps: fps,
            renderer: renderer,
            persistArtifactToItemID: record.id,
            progress: progress
        )
    }

    /// 资格写入后后台自动烘焙（推荐/边缘档位）；已有同 `analysisId` 成品则跳过。
    static func scheduleAutoBakeAfterEligibility(itemID: String) {
        Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let record = await MainActor.run { () -> MediaDownloadRecord? in
                MediaLibraryService.shared.downloadedItems.first { $0.item.id == itemID }
            }
            guard let record,
                  let eligibility = record.sceneBakeEligibility else { return }
            guard SystemMemoryPressure.hasRoomForSceneOfflineBake() else {
                print("[SceneOfflineBake] auto-bake skipped: insufficient reclaimable memory")
                return
            }
            if let art = record.sceneBakeArtifact,
               art.analysisId == eligibility.analysisId,
               (art.renderer == nil || art.renderer == .wallpaperWgpu),
               isUsableBakedVideo(at: URL(fileURLWithPath: art.videoPath)) {
                return
            }
            do {
                _ = try await bake(record: record) { @MainActor progress in
                    NotificationCenter.default.post(
                        name: .sceneOfflineBakeProgressDidUpdate,
                        object: itemID,
                        userInfo: ["progress": progress]
                    )
                }
                print("[SceneOfflineBake] auto-bake finished \(itemID)")
            } catch {
                if case SceneOfflineBakeError.concurrentBakeInProgress = error {
                    print("[SceneOfflineBake] auto-bake skipped (busy) \(itemID)")
                } else {
                    print("[SceneOfflineBake] auto-bake failed \(itemID): \(error.localizedDescription)")
                }
            }
        }
    }

    static func isUsableBakedVideo(at url: URL) -> Bool {
        inspectBakedVideoSync(at: url) != nil
    }

    private static func mainDisplayPixelSize() -> (width: Int, height: Int) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let displayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let cgDisplayID = CGDirectDisplayID(displayID.uint32Value)
            let width = CGDisplayPixelsWide(cgDisplayID)
            let height = CGDisplayPixelsHigh(cgDisplayID)
            if width > 0, height > 0 {
                print("[SceneOfflineBake] main display pixels: \(width)x\(height)")
                return (width, height)
            }
        }

        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let scale = screen?.backingScaleFactor ?? 1
        let width = max(64, Int((frame.width * scale).rounded()))
        let height = max(64, Int((frame.height * scale).rounded()))
        print("[SceneOfflineBake] fallback main display size: \(width)x\(height)")
        return (width, height)
    }

    private static func inspectBakedVideo(at url: URL, expectedWidth: Int? = nil, expectedHeight: Int? = nil) async -> BakedVideoInspection? {
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.int64Value > 10_000 else {
            return nil
        }

        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration)
        guard let durationSec = duration?.seconds, durationSec.isFinite, durationSec > 0.5 else { return nil }
        guard let track = (try? await asset.loadTracks(withMediaType: .video))?.first else { return nil }
        let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        let preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        let transformedSize = naturalSize.applying(preferredTransform)
        let width = abs(Int(transformedSize.width.rounded()))
        let height = abs(Int(transformedSize.height.rounded()))
        guard width > 0, height > 0 else { return nil }
        if let expectedWidth, let expectedHeight, (width != expectedWidth || height != expectedHeight) {
            print("[SceneOfflineBake] invalid cached MP4 size: actual=\(width)x\(height) expected=\(expectedWidth)x\(expectedHeight) url=\(url.path)")
            return nil
        }
        return BakedVideoInspection(duration: durationSec, width: width, height: height)
    }

    private static func inspectBakedVideoSync(at url: URL, expectedWidth: Int? = nil, expectedHeight: Int? = nil) -> BakedVideoInspection? {
        final class Box: @unchecked Sendable { var value: BakedVideoInspection? }
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        DispatchQueue.global().async {
            Task {
                box.value = await inspectBakedVideo(at: url, expectedWidth: expectedWidth, expectedHeight: expectedHeight)
                semaphore.signal()
            }
        }
        semaphore.wait()
        return box.value
    }
}
