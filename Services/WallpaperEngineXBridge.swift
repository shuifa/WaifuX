import Foundation
import AppKit
import Combine
import WebKit

private let webPrimaryCapturePath = "/tmp/wallpaperengine-web-capture.png"
private let webDeskCapturePath0 = "/tmp/wallpaperengine-web-desk-0.png"
private let webDeskCapturePath1 = "/tmp/wallpaperengine-web-desk-1.png"
private let legacyCLIWebCapturePath = "/tmp/wallpaperengine-cli-capture.png"

private struct SavedOriginalWallpaperState: Codable {
    let configs: [ScreenWallpaperConfig]
    let savedAt: Date
    let appVersion: String
}

private struct ScreenWallpaperConfig: Codable {
    let screenID: String
    let screenName: String
    let wallpaperURL: String
    let isMainScreen: Bool
}

/// 进程终止事件（线程安全，通过 os_unfair_lock 传递到 @MainActor）
private struct TerminationEvent: @unchecked Sendable {
    let pid: pid_t
    let generation: UInt64
    let status: Int32
    let reason: Process.TerminationReason
}

/// 检查是否有屏幕录制权限（同步，禁止调用时直接崩溃）
private func checkScreenCapturePermission() -> Bool {
    if #available(macOS 10.15, *) {
        return CGPreflightScreenCaptureAccess()
    }
    return true
}

/// 请求屏幕录制权限。真实截取外部 renderer 窗口必须走系统授权，不能用预览图替代。
private func requestScreenCapturePermission() async -> Bool {
    if #available(macOS 10.15, *) {
        if CGPreflightScreenCaptureAccess() { return true }
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: CGRequestScreenCaptureAccess())
            }
        }
    }
    return true
}

private struct RendererWrapperBundle: Sendable {
    let bundleURL: URL
    let executableURL: URL
    let renderedBinaryURL: URL
}

// MARK: - CGS 私有 API 桥接（桌面层级/标签设置）
// macOS 26 已移除 CGSWindowByID，且 `--wallpaper`/`--background` 参数已自带后台壁纸渲染能力，
// 因此不再使用 CGS API。窗口标签（Stationary/CanJoinAllSpaces）由二进制处理。

/// 负责与 wallpaper-wgpu 渲染器通信的桥接层
///
/// **设计变化（相对于旧 wallpaperengine-cli，已废弃）：**
/// - 旧版：通过 Unix Socket IPC 与 daemon 进程通信，支持 set/stop/pause/resume 命令
/// - 新版：直接管理 wallpaper-wgpu 进程，通过 SIGSTOP/SIGCONT 暂停/恢复，terminate() 停止
///
/// **scene** 均由 wallpaper-wgpu 渲染，与本机视频壁纸一样属于「动态壁纸」：
/// `isControllingExternalEngine` 为真时菜单栏应走 pause/resume/stop 走此桥接层，
/// 而非 `VideoWallpaperManager`。
@MainActor
final class WallpaperEngineXBridge: ObservableObject {
    static let shared = WallpaperEngineXBridge()

    private struct ScreenConfigurationSignature: Equatable {
        let screenID: String
        let originX: Int
        let originY: Int
        let width: Int
        let height: Int
        let scale: Int

        init(screen: NSScreen) {
            let frame = screen.frame
            self.screenID = screen.wallpaperScreenIdentifier
            self.originX = Self.quantize(frame.origin.x)
            self.originY = Self.quantize(frame.origin.y)
            self.width = Self.quantize(frame.width)
            self.height = Self.quantize(frame.height)
            self.scale = Self.quantize(screen.backingScaleFactor)
        }

        private static func quantize(_ value: CGFloat) -> Int {
            Int((value * 1000).rounded())
        }
    }

    // MARK: - Published State

    /// 当前是否由 wallpaper-wgpu 接管桌面壁纸
    @Published private(set) var isControllingExternalEngine = false
    @Published private(set) var isExternalPaused = false

    // MARK: - 进程管理

    /// wallpaper-wgpu 进程实例
    private var renderProcess: Process?
    private var renderBundleURL: URL?
    private let webRenderer = WebRendererBridge.shared
    private enum RenderKind {
        case scene
        case web
    }
    private var activeRenderKind: RenderKind?
    /// 当前渲染进程的 PID（用于 SIGSTOP/SIGCONT）
    private var renderPID: pid_t? {
        didSet { _deinitPID = renderPID }
    }
    /// 进程终止 watchdog 工作项（超时强制 SIGKILL）
    private var terminationWatchdog: DispatchWorkItem?
    /// 非隔离存储 PID，供 deinit 中安全清理
    private nonisolated(unsafe) var _deinitPID: pid_t?
    /// 启动批次号，防止旧进程的 terminationHandler 污染新进程状态
    private var launchGeneration: UInt64 = 0

    // MARK: - 线程安全的进程终止事件管道

    /// terminationHandler 在后台线程执行，不能用任何闭包方式传递到 @MainActor（Swift 6 断言拦截）。
    /// 改用 os_unfair_lock 指针保护的标志位，由 @MainActor 方法择机消费。
    private nonisolated(unsafe) let terminationLockPtr: UnsafeMutablePointer<os_unfair_lock> = {
        let ptr = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        ptr.initialize(to: os_unfair_lock())
        return ptr
    }()
    private nonisolated(unsafe) var pendingTermination: TerminationEvent?
    private nonisolated(unsafe) var terminationPendingFlag = false

    // MARK: - 防重复启动锁

    /// 正在设置壁纸中（防止 `restoreIfNeeded` 等场景重复调用 `setWallpaper`）
    private var isSettingWallpaper = false

    // MARK: - 持久化状态

    private var lastWallpaperPath: String?
    private var targetScreenIDs = Set<String>()
    private var targetScreenFingerprints = Set<String>()
    private var cancellables = Set<AnyCancellable>()

    private let lastWallpaperPathKey = "we_last_wallpaper_path_v1"
    private let controllingExternalKey = "we_controlling_external_v1"
    private let targetScreenIDsKey = "we_target_screen_ids_v1"
    private let targetScreenFingerprintsKey = "we_target_screen_fingerprints_v1"

    // MARK: - 屏幕变化观察

    /// 屏幕参数变化（分辨率、显示器热插拔等）时重启渲染进程
    private var screenChangeRestartWorkItem: DispatchWorkItem?
    private var lastAppliedScreenConfigurations: [ScreenConfigurationSignature] = []
    private static let rendererWrapperBundleIdentifier = "com.waifux.wallpaperwgpu.wrapper"

    // MARK: - 初始化

    private init() {
        // 监听 VideoWallpaperManager 恢复自己播放时，清空外部接管标记。
        // 显式 @MainActor 标注闭包，不加 Task { @MainActor } 包装（包装本身也会触发断言）
        VideoWallpaperManager.shared.$currentVideoURL
            .receive(on: DispatchQueue.main)
            .sink { @MainActor [weak self] url in
                guard let self = self else { return }
                if url != nil {
                    let nativeScreenIDs = Set(VideoWallpaperManager.shared.activeScreens.map(\.wallpaperScreenIdentifier))
                    let cliScreenIDs = self.targetScreenIDs
                    let overlap = cliScreenIDs.intersection(nativeScreenIDs)
                    if cliScreenIDs.isEmpty || !overlap.isEmpty {
                        self.isControllingExternalEngine = false
                        self.isExternalPaused = false
                        self.targetScreenIDs.removeAll()
                        self.targetScreenFingerprints.removeAll()
                    }
                }
            }
            .store(in: &cancellables)

        // 监听屏幕参数变化（分辨率变更、显示器连接/断开）
        // 用 Combine publisher 替代 addObserver（后者不接受 @MainActor 闭包）
        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .receive(on: DispatchQueue.main)
        .sink { @MainActor [weak self] _ in
            guard let self = self else { return }
            self.handleScreenParametersChanged()
        }
        .store(in: &self.cancellables)
    }

    deinit {
        if let pid = _deinitPID, kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }

    // MARK: - App 可用性

    var isWallpaperEngineXInstalled: Bool {
        WorkshopService.isWallpaperEngineAppInstalled()
    }

    var isWallpaperEngineXRunning: Bool {
        let bundleId = "com.WallpaperEngineX.app"
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    var currentWallpaperPathForDesign: String? {
        lastWallpaperPath
    }

    func reloadCurrentSceneWallpaperForDesign() {
        guard isCurrentWallpaperScene, let path = lastWallpaperPath else { return }
        Task { @MainActor in
            try? await setWallpaper(path: path)
        }
    }

    var isCurrentWallpaperWeb: Bool {
        isControllingExternalEngine && activeRenderKind == .web
    }

    var isCurrentWallpaperScene: Bool {
        isControllingExternalEngine && activeRenderKind == .scene
    }

    // MARK: - 设置壁纸

    /// 使用 wallpaper-wgpu 设置动态壁纸
    /// - Parameters:
    ///   - path: 壁纸目录或 scene.pkg 路径
    ///   - assetsPath: assets-pc 资源目录路径（nil 时从内嵌 assets 解压）
    ///   - targetScreens: 目标屏幕列表（nil 表示所有屏幕）
    func setWallpaper(path: String, assetsPath: String? = nil, targetScreens: [NSScreen]? = nil) async throws {
        print("[WallpaperEngineXBridge] >>> setWallpaper START path=\(path)")

        // 处理之前堆积的进程终止事件
        processPendingTermination()

        // 防重复启动：恢复桌面时可能多次触发，串行化处理
        guard !isSettingWallpaper else {
            print("[WallpaperEngineXBridge] ⚠️ 已有壁纸设置任务进行中，跳过")
            return
        }
        isSettingWallpaper = true
        defer {
            isSettingWallpaper = false
            print("[WallpaperEngineXBridge] <<< setWallpaper END")
        }

        // 更新批次号，避免旧的终止事件污染新状态
        launchGeneration &+= 1

        let resolvedPath = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: URL(fileURLWithPath: path)).path
        let renderKind: RenderKind = isWebWallpaper(path: resolvedPath) ? .web : .scene

        if renderKind == .scene {
            print("[WallpaperEngineXBridge] step 0: 检查真实帧捕获权限")
            guard await requestScreenCapturePermission() else {
                print("[WallpaperEngineXBridge] ❌ 屏幕录制权限被拒绝，无法截取 wallpaper-wgpu 真实渲染帧")
                throw WallpaperEngineError.screenCaptureDenied
            }
        }

        print("[WallpaperEngineXBridge] step 1: 停止本机视频层")

        // 1. 只停本机视频层；切勿调用 `VideoWallpaperManager.stopWallpaper()`（会恢复静态桌面）
        if let screens = targetScreens, !screens.isEmpty {
            for screen in screens {
                VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: screen)
            }
        } else {
            VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly()
        }

        // macOS 26+：清空旧的锁屏镜像帧源缓存。
        // wallpaper-wgpu 渲染的壁纸不参与锁屏镜像推帧，但若用户已在设置中启用
        // 动态锁屏，则不应清除其缓存，否则锁屏会退化回静态壁纸。
        // 使用持久化设置 isLockScreenEnabled 而非 isLockScreenMirroringActive。
        if #available(macOS 26.0, *) {
            if !VideoWallpaperManager.shared.isLockScreenEnabled {
                LockScreenWallpaperService.shared.clearMirroringSourceCache()
            }
        }

        // 2. 终止旧进程
        if #available(macOS 26.0, *) {
            LockScreenWallpaperService.shared.clearRealtimeSourceIfNeeded(notify: renderKind != .web)
        }
        await stopRenderProcessBeforeLaunch()
        // 如果上一张是 web 壁纸，旧 CLI 的 daemon 仍在跑；切到 scene/新 web 之前必须先停掉，
        // 否则两个壁纸层会在桌面叠加显示。
        Self.killLegacyDaemonIfRunning(waitForExit: true)
        webRenderer.stop()

        // 3. 保存状态
        lastWallpaperPath = resolvedPath
        isExternalPaused = false
        isControllingExternalEngine = true
        activeRenderKind = renderKind
        if let screens = targetScreens, !screens.isEmpty {
            targetScreenIDs = Set(screens.map(\.wallpaperScreenIdentifier))
            targetScreenFingerprints = Set(screens.map(\.wallpaperScreenFingerprint))
            // ⚠️ 多显示器提示：wallpaper-wgpu 实时渲染仅支持主屏
            if screens.count > 1 {
                print("[WallpaperEngineXBridge] ⚠️ 检测到 \(screens.count) 个目标屏幕，但 wallpaper-wgpu 实时渲染只支持主屏")
            }
        } else {
            targetScreenIDs = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))
            targetScreenFingerprints = Set(NSScreen.screens.map(\.wallpaperScreenFingerprint))
            if NSScreen.screens.count > 1 {
                print("[WallpaperEngineXBridge] ⚠️ 检测到 \(NSScreen.screens.count) 个显示器，但 wallpaper-wgpu 实时渲染只支持主屏")
            }
        }
        lastAppliedScreenConfigurations = currentTargetScreenConfigurations()
        persistState()

        if renderKind == .web {
            try await setWebWallpaper(path: resolvedPath, targetScreens: targetScreens)
            DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            return
        }

        // 4. 解析 assets 路径
        let resolvedAssets: String
        if let ap = assetsPath, !ap.isEmpty {
            resolvedAssets = ap
        } else if let embedded = WallpaperEngineEmbeddedAssets.materializedAssetsRootIfPresent() {
            resolvedAssets = embedded
        } else {
            resolvedAssets = ""
        }

        // 5. 启动 wallpaper-wgpu
        guard let cliURL = Self.resolvedCLIExecutableURL() else {
            print("[WallpaperEngineXBridge] ❌ wallpaper-wgpu 二进制未找到，已搜索所有路径")
            throw WallpaperEngineError.cliNotFound
        }
        print("[WallpaperEngineXBridge] wallpaper-wgpu 路径: \(cliURL.path)")

        // 参数格式: --release -- <path> --assets <assets> --wallpaper --background
        var args = ["--release", "--", resolvedPath]
        if !resolvedAssets.isEmpty {
            args += ["--assets", resolvedAssets]
            print("[WallpaperEngineXBridge] assets 路径: \(resolvedAssets)")
        } else {
            print("[WallpaperEngineXBridge] ⚠️ assets 为空，未传入 --assets 参数")
        }
        args += ["--wallpaper", "--background"]

        print("[WallpaperEngineXBridge] 启动命令: \(cliURL.lastPathComponent) \(args.joined(separator: " "))")

        let launchedPID: pid_t
        do {
            let wrapper = try Self.prepareRendererWrapper(for: cliURL)
            launchedPID = try await launchRendererWrapper(wrapper, arguments: args)
            renderBundleURL = wrapper.bundleURL
            renderPID = launchedPID
            print("[WallpaperEngineXBridge] ✅ wallpaper-wgpu wrapper 已启动 (pid=\(launchedPID))")
        } catch {
            print("[WallpaperEngineXBridge] ❌ 启动 wallpaper-wgpu 失败: \(error.localizedDescription)")
            renderProcess = nil
            renderPID = nil
            renderBundleURL = nil
            isControllingExternalEngine = false
            throw WallpaperEngineError.executionFailed("启动 wallpaper-wgpu 失败: \(error.localizedDescription)")
        }

        DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()

        // 6. 真实渲染已经启动，UI 可立即结束“设置中”状态。
        //    窗口确认和静态锁屏/fallback 首帧捕获较慢，放后台继续做，避免按钮长时间转圈。
        Task { @MainActor in
            guard self.renderPID == launchedPID, self.lastWallpaperPath == resolvedPath else { return }
            await self.adoptRenderWindow(pid: launchedPID)
            guard self.renderPID == launchedPID, self.lastWallpaperPath == resolvedPath else { return }
            let captured = await self.captureStaticFallbackFrame(path: resolvedPath, expectedPID: launchedPID)
            if !captured {
                print("[WallpaperEngineXBridge] ⚠️ 真实渲染帧捕获失败，实时渲染已启动，但未更新静态桌面/锁屏 fallback")
            }
        }
    }

    // MARK: - 暂停 / 恢复 / 停止

    /// 暂停渲染（发送 SIGSTOP）
    func pauseWallpaper() {
        if activeRenderKind == .web {
            // web 渲染由旧 CLI 的 daemon 持有，必须通过其 IPC 暂停
            Task { try? await Self.runLegacyCLIClientCommand(["pause"]) }
            webRenderer.pause()
            isExternalPaused = true
            return
        }
        guard let pid = renderPID, isControllingExternalEngine else { return }
        kill(pid, SIGSTOP)
        isExternalPaused = true
        print("[WallpaperEngineXBridge] 暂停渲染 (pid=\(pid))")
    }

    /// 恢复渲染（发送 SIGCONT）
    func resumeWallpaper() {
        if activeRenderKind == .web {
            Task { try? await Self.runLegacyCLIClientCommand(["resume"]) }
            webRenderer.resume()
            isExternalPaused = false
            return
        }
        guard let pid = renderPID, isControllingExternalEngine else { return }
        kill(pid, SIGCONT)
        isExternalPaused = false
        print("[WallpaperEngineXBridge] 恢复渲染 (pid=\(pid))")
    }

    /// 切换暂停/恢复
    func toggleWallpaper() {
        guard isControllingExternalEngine else { return }
        if isExternalPaused {
            resumeWallpaper()
        } else {
            pauseWallpaper()
        }
    }

    /// 停止渲染（终止进程）
    func stopWallpaper() {
        ensureStoppedForNonCLIWallpaper()
    }

    /// 切换为**非** wallpaper-wgpu 壁纸时必须调用
    func ensureStoppedForNonCLIWallpaper() {
        if #available(macOS 26.0, *) {
            LockScreenWallpaperService.shared.clearRealtimeSourceIfNeeded()
        }
        stopRenderProcess()
        // 同步杀掉旧 CLI daemon（fire-and-forget 的 client 命令在 App 退出场景来不及发出，
        // 且 stop client 自己还会再 fork daemon — 直接按 PID kill 最稳妥）
        Self.killLegacyDaemonIfRunning(waitForExit: false)
        webRenderer.stop()
        activeRenderKind = nil
        isControllingExternalEngine = false
        isExternalPaused = false
        targetScreenIDs.removeAll()
        targetScreenFingerprints.removeAll()
        lastAppliedScreenConfigurations.removeAll()
        UserDefaults.standard.removeObject(forKey: controllingExternalKey)
        UserDefaults.standard.removeObject(forKey: targetScreenIDsKey)
        UserDefaults.standard.removeObject(forKey: targetScreenFingerprintsKey)
    }

    /// 应用退出前调用：终止当前接管的 renderer，但保留持久化状态，方便下次启动恢复。
    func prepareForAppTermination() {
        stopRenderProcess(waitForExit: true)
        // 必须同步等待 daemon 退出 — App 一旦走 NSApp.terminate，Task/异步 client 全部来不及执行，
        // daemon 子进程不是主进程的子进程组成员，不会被自动清理，会导致 web 壁纸残留。
        Self.killLegacyDaemonIfRunning(waitForExit: true)
        webRenderer.stop()
        isControllingExternalEngine = false
        isExternalPaused = false
        targetScreenIDs.removeAll()
        targetScreenFingerprints.removeAll()
        lastAppliedScreenConfigurations.removeAll()
    }

    /// 同步终止 `/tmp/wallpaperengine-cli.pid` 指向的 daemon 进程（无视 `activeRenderKind`）。
    /// App 退出 / 切换壁纸时使用，避免遗留 daemon 持续渲染 web 壁纸。
    private static func killLegacyDaemonIfRunning(waitForExit: Bool) {
        let pidPath = "/tmp/wallpaperengine-cli.pid"
        guard let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8) else {
            return
        }
        let trimmed = pidStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(trimmed), pid > 0, kill(pid, 0) == 0 else {
            // 进程已经不在了，顺手清掉过期的 PID 文件
            try? FileManager.default.removeItem(atPath: pidPath)
            return
        }

        print("[WallpaperEngineXBridge] 终止旧 CLI daemon (pid=\(pid)) waitForExit=\(waitForExit)")
        kill(pid, SIGTERM)

        if waitForExit {
            let deadline = Date().addingTimeInterval(1.5)
            while kill(pid, 0) == 0 && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if kill(pid, 0) == 0 {
                print("[WallpaperEngineXBridge] daemon 未响应 SIGTERM，改发 SIGKILL")
                kill(pid, SIGKILL)
                let killDeadline = Date().addingTimeInterval(0.5)
                while kill(pid, 0) == 0 && Date() < killDeadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
            }
        }

        try? FileManager.default.removeItem(atPath: pidPath)
    }

    private func setWebWallpaper(path: String, targetScreens: [NSScreen]?) async throws {
        let screenIndex: Int?
        if let screen = targetScreens?.first {
            screenIndex = NSScreen.screens.firstIndex(of: screen)
        } else {
            screenIndex = nil
        }

        // ✅ Web 壁纸改走旧 wallpaperengine-cli：daemon 自带 WKWebView 桥，能正确处理 web 类型项目。
        //    原内置 WebRendererBridge 在新流程中已不参与启动，仅作为停止时的清场调用保留。
        var args = ["set", path]
        if let idx = screenIndex {
            args.append(String(idx))
        }

        print("[WallpaperEngineXBridge] 使用旧 wallpaperengine-cli 设置 Web 壁纸: \(path) screenIdx=\(screenIndex.map(String.init) ?? "all")")
        try? FileManager.default.removeItem(atPath: legacyCLIWebCapturePath)
        let status = try await Self.runLegacyCLIClientCommand(args)
        guard status == 0 else {
            throw WallpaperEngineError.executionFailed("wallpaperengine-cli set 失败 (exit=\(status))")
        }

        if let propertiesJSON = try? WebWallpaperDesignService.shared.effectivePropertiesJSON(for: path),
           !propertiesJSON.isEmpty {
            try? await applyWebWallpaperProperties(propertiesJSON)
        }

        let captureURL = await captureWebFallbackFrameForLockScreenIfNeeded()
        await syncWebStaticFrameToLockScreenIfNeeded(imageURL: captureURL, targetScreens: targetScreens)
    }

    private func syncWebStaticFrameToLockScreenIfNeeded(imageURL: URL?, targetScreens: [NSScreen]?) async {
        guard #available(macOS 26.0, *) else { return }
        guard VideoWallpaperManager.shared.isLockScreenEnabled else { return }
        guard UserDefaults.standard.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else { return }
        guard let imageURL, FileManager.default.fileExists(atPath: imageURL.path) else {
            print("[WallpaperEngineXBridge] ⚠️ Web 锁屏静态帧未生成，跳过扩展静态图同步")
            return
        }

        let screens = targetScreens?.isEmpty == false ? targetScreens! : NSScreen.screens
        let displayIDs = screens.compactMap { screen -> UInt32? in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        guard !displayIDs.isEmpty else {
            print("[WallpaperEngineXBridge] ⚠️ 未找到目标显示器，Web 锁屏静态帧同步已跳过")
            return
        }

        do {
            try await LockScreenWallpaperService.shared.cacheStaticImageSource(imageURL: imageURL, displayIDs: displayIDs)
            print("[WallpaperEngineXBridge] 🖼️ 已将 Web 首帧按静态图同步到锁屏扩展 display=\(displayIDs)")
        } catch {
            print("[WallpaperEngineXBridge] ⚠️ Web 锁屏静态帧同步失败: \(error.localizedDescription)")
        }
    }

    private func captureWebFallbackFrameForLockScreenIfNeeded() async -> URL? {
        guard #available(macOS 26.0, *) else { return nil }
        guard VideoWallpaperManager.shared.isLockScreenEnabled else { return nil }
        guard UserDefaults.standard.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else { return nil }

        if FileManager.default.fileExists(atPath: legacyCLIWebCapturePath) {
            return URL(fileURLWithPath: legacyCLIWebCapturePath)
        }

        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if FileManager.default.fileExists(atPath: legacyCLIWebCapturePath) {
                return URL(fileURLWithPath: legacyCLIWebCapturePath)
            }
        }

        return nil
    }

    /// 启动旧 `wallpaperengine-cli` 的客户端子命令（set/pause/resume/stop）。
    /// 这些命令仅作为 IPC 客户端，向 daemon 发完消息就退出；真正的 web 渲染由 daemon 持有。
    @discardableResult
    private static func runLegacyCLIClientCommand(_ arguments: [String]) async throws -> Int32 {
        guard let cli = SceneOfflineBakeService.resolvedLegacyCLIExecutableURL() else {
            throw WallpaperEngineError.cliNotFound
        }
        let env = legacyCLILaunchEnvironment(for: cli)
        let processTask = Task.detached(priority: .userInitiated) { () throws -> Int32 in
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        return try await processTask.value
    }

    func applyWebWallpaperProperties(_ propertiesJSON: String) async throws {
        guard isCurrentWallpaperWeb else {
            throw WallpaperEngineError.executionFailed("当前没有运行中的 Web 壁纸")
        }
        let status = try await Self.runLegacyCLIClientCommand(["apply-properties", propertiesJSON])
        guard status == 0 else {
            throw WallpaperEngineError.executionFailed("Web 壁纸属性热更新失败 (exit=\(status))")
        }
    }

    /// 给旧 CLI 客户端进程拼装 DYLD 路径，复用 `bakeWithLegacyCLI` 的搜索策略。
    private static func legacyCLILaunchEnvironment(for cli: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["LSUIElement"] = "1"
        if #available(macOS 26.0, *) {
            env["WAIFUX_DYNAMIC_LOCK_SCREEN_ENABLED"] = VideoWallpaperManager.shared.isLockScreenEnabled ? "1" : "0"
        } else {
            env["WAIFUX_DYNAMIC_LOCK_SCREEN_ENABLED"] = "0"
        }
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
        return env
    }

    private static func prepareRendererWrapper(for rendererURL: URL) throws -> RendererWrapperBundle {
        let fm = FileManager.default
        let cacheBase = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let wrapperRoot = cacheBase
            .appendingPathComponent("com.waifux.wallpaperengine", isDirectory: true)
            .appendingPathComponent("RendererWrapper", isDirectory: true)
        let bundleURL = wrapperRoot.appendingPathComponent("WallpaperWGPUAgent.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let executableURL = macOSURL.appendingPathComponent("wallpaper-wgpu-launcher")

        try fm.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>en</string>
            <key>CFBundleExecutable</key>
            <string>wallpaper-wgpu-launcher</string>
            <key>CFBundleIdentifier</key>
            <string>\(Self.rendererWrapperBundleIdentifier)</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>Wallpaper WGPU Agent</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>LSBackgroundOnly</key>
            <false/>
            <key>LSUIElement</key>
            <true/>
            <key>NSHighResolutionCapable</key>
            <true/>
        </dict>
        </plist>
        """
        try infoPlist.data(using: .utf8)?.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)

        let launcher = """
        #!/bin/zsh
        cd \(Self.shellSingleQuoted(rendererURL.deletingLastPathComponent().path))
        exec \(Self.shellSingleQuoted(rendererURL.path)) "$@"
        """
        try launcher.data(using: .utf8)?.write(to: executableURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        return RendererWrapperBundle(
            bundleURL: bundleURL,
            executableURL: executableURL,
            renderedBinaryURL: rendererURL
        )
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func launchRendererWrapper(_ wrapper: RendererWrapperBundle, arguments: [String]) async throws -> pid_t {
        let rendererDirectory = wrapper.renderedBinaryURL.deletingLastPathComponent()
        let rendererLibDirectory = rendererDirectory.appendingPathComponent("lib")
        let bundleResourceDirectory = rendererDirectory.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment

        let searchPaths = [
            rendererDirectory.path,
            bundleResourceDirectory.path,
            environment["PATH"] ?? "",
        ].filter { !$0.isEmpty }
        environment["PATH"] = searchPaths.joined(separator: ":")
        environment["DYLD_LIBRARY_PATH"] = [
            rendererLibDirectory.path,
            bundleResourceDirectory.appendingPathComponent("lib").path,
            environment["DYLD_LIBRARY_PATH"] ?? ""
        ].filter { !$0.isEmpty }.joined(separator: ":")

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.environment = environment
        configuration.activates = false
        configuration.createsNewApplicationInstance = true

        let app = try await NSWorkspace.shared.openApplication(at: wrapper.bundleURL, configuration: configuration)
        return app.processIdentifier
    }

    // MARK: - 进程生命周期管理

    private func terminateRenderer(pid: pid_t) {
        if let process = renderProcess, process.processIdentifier == pid {
            process.terminate()
            return
        }
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) {
            app.terminate()
            return
        }
        kill(pid, SIGTERM)
    }

    /// 终止渲染进程
    private func stopRenderProcess(waitForExit: Bool = false) {
        // 先处理已堆积的终止事件，避免与新进程状态混淆
        processPendingTermination()

        screenChangeRestartWorkItem?.cancel()
        screenChangeRestartWorkItem = nil
        terminationWatchdog?.cancel()
        terminationWatchdog = nil
        activeRenderKind = activeRenderKind == .scene ? nil : activeRenderKind

        guard let pid = renderPID else {
            renderProcess = nil
            renderPID = nil
            renderBundleURL = nil
            return
        }

        // 先优雅终止
        terminateRenderer(pid: pid)

        if waitForExit {
            let deadline = Date().addingTimeInterval(2.0)
            while kill(pid, 0) == 0 && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }

            if kill(pid, 0) == 0 {
                print("[WallpaperEngineXBridge] 退出前 renderer 未及时退出，发送 SIGKILL (pid=\(pid))")
                kill(pid, SIGKILL)
                let killDeadline = Date().addingTimeInterval(0.5)
                while kill(pid, 0) == 0 && Date() < killDeadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
            }
        }

        // 设置 watchdog：2 秒后强制 SIGKILL
        if !waitForExit {
            let watchdog = DispatchWorkItem {
                if kill(pid, 0) == 0 {
                    print("[WallpaperEngineXBridge] 进程未响应 terminate，发送 SIGKILL (pid=\(pid))")
                    kill(pid, SIGKILL)
                }
            }
            terminationWatchdog = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: watchdog)
        }

        renderProcess = nil
        renderPID = nil
        renderBundleURL = nil
        if activeRenderKind == .scene {
            activeRenderKind = nil
        }
    }

    /// 启动新 renderer 前必须确认旧 renderer 已退出，避免“旧进程还在收尾，新进程又被启动”的闪烁和竞态。
    private func stopRenderProcessBeforeLaunch() async {
        processPendingTermination()

        screenChangeRestartWorkItem?.cancel()
        screenChangeRestartWorkItem = nil
        terminationWatchdog?.cancel()
        terminationWatchdog = nil

        guard let pid = renderPID else {
            renderProcess = nil
            renderPID = nil
            renderBundleURL = nil
            return
        }

        terminateRenderer(pid: pid)

        let deadline = Date().addingTimeInterval(2.0)
        while kill(pid, 0) == 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if kill(pid, 0) == 0 {
            print("[WallpaperEngineXBridge] 旧 renderer 未及时退出，发送 SIGKILL (pid=\(pid))")
            kill(pid, SIGKILL)
            let killDeadline = Date().addingTimeInterval(0.5)
            while kill(pid, 0) == 0 && Date() < killDeadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        renderProcess = nil
        renderPID = nil
        renderBundleURL = nil
        processPendingTermination()
    }

    /// 消费线程安全的进程终止事件（@MainActor 方法，仅供其他 @MainActor 方法调用）
    private func processPendingTermination() {
        let event: TerminationEvent? = {
            os_unfair_lock_lock(terminationLockPtr)
            defer { os_unfair_lock_unlock(terminationLockPtr) }
            let e = pendingTermination
            pendingTermination = nil
            terminationPendingFlag = false
            return e
        }()

        guard let event = event else { return }
        guard event.generation == launchGeneration else { return }

        // SIGTERM (exit code 15) 是由 terminate() 主动发出的正常终止信号
        if event.reason == .uncaughtSignal && event.status == 15 {
            print("[WallpaperEngineXBridge] wallpaper-wgpu 已正常终止 (pid=\(event.pid), 收到 SIGTERM)")
        } else if event.status != 0 {
            print("[WallpaperEngineXBridge] ❌ wallpaper-wgpu 异常退出 (pid=\(event.pid), 退出码=\(event.status), reason=\(event.reason.rawValue))")
        } else {
            print("[WallpaperEngineXBridge] wallpaper-wgpu 已正常退出 (pid=\(event.pid))")
        }

        if renderPID == event.pid {
            renderProcess = nil
            renderPID = nil
            if isControllingExternalEngine {
                isControllingExternalEngine = false
                isExternalPaused = false
                targetScreenIDs.removeAll()
                targetScreenFingerprints.removeAll()
            }
        }
    }

    // MARK: - 状态恢复

    func restoreIfNeeded() async {
        // 已在控制中（上一个 restore 已完成），跳过避免重复启动
        guard !isControllingExternalEngine else {
            print("[WallpaperEngineXBridge] restoreIfNeeded: 已处于控制状态，跳过")
            return
        }

        if let path = UserDefaults.standard.string(forKey: lastWallpaperPathKey) {
            lastWallpaperPath = path
        }
        targetScreenIDs = Set(UserDefaults.standard.stringArray(forKey: targetScreenIDsKey) ?? [])
        targetScreenFingerprints = Set(UserDefaults.standard.stringArray(forKey: targetScreenFingerprintsKey) ?? [])

        guard UserDefaults.standard.bool(forKey: controllingExternalKey) else { return }
        guard let path = lastWallpaperPath else { return }

        // ✅ 检查路径是否存在，不存在则清除持久化状态，避免启动已失效的渲染器
        guard FileManager.default.fileExists(atPath: path) else {
            print("[WallpaperEngineXBridge] 持久化的壁纸路径已不存在，清除状态: \(path)")
            clearPersistedState()
            lastWallpaperPath = nil
            targetScreenIDs.removeAll()
            targetScreenFingerprints.removeAll()
            return
        }

        let hasPersistedTargets = !targetScreenIDs.isEmpty || !targetScreenFingerprints.isEmpty
        let screens = hasPersistedTargets ? activeTargetScreens() : []
        try? await setWallpaper(path: path, targetScreens: hasPersistedTargets && !screens.isEmpty ? screens : nil)
    }

    // MARK: - 持久化

    private func persistState() {
        if let path = lastWallpaperPath {
            UserDefaults.standard.set(path, forKey: lastWallpaperPathKey)
            UserDefaults.standard.set(isControllingExternalEngine, forKey: controllingExternalKey)
            UserDefaults.standard.set(Array(targetScreenIDs), forKey: targetScreenIDsKey)
            UserDefaults.standard.set(Array(targetScreenFingerprints), forKey: targetScreenFingerprintsKey)
        } else {
            clearPersistedState()
        }
    }

    private func clearPersistedState() {
        UserDefaults.standard.removeObject(forKey: lastWallpaperPathKey)
        UserDefaults.standard.removeObject(forKey: controllingExternalKey)
        UserDefaults.standard.removeObject(forKey: targetScreenIDsKey)
        UserDefaults.standard.removeObject(forKey: targetScreenFingerprintsKey)
    }

    /// 检查 wallpaper-wgpu 是否正在管理指定屏幕
    func isManaging(screen: NSScreen) -> Bool {
        targetScreenIDs.contains(screen.wallpaperScreenIdentifier) ||
        targetScreenFingerprints.contains(screen.wallpaperScreenFingerprint)
    }

    /// 检查一组屏幕 ID 中是否有被外部引擎管理的屏幕
    func shouldPauseForFullscreenCoveredScreenIDs(_ coveredIDs: Set<String>) -> Bool {
        !coveredIDs.isDisjoint(with: targetScreenIDs)
    }

    /// 批量更新持久化状态中的壁纸路径（目录迁移后调用）
    func bulkUpdatePaths(oldPrefix: String, newPrefix: String) {
        guard let path = UserDefaults.standard.string(forKey: lastWallpaperPathKey) else { return }
        if path.hasPrefix(oldPrefix) {
            let newPath = newPrefix + String(path.dropFirst(oldPrefix.count))
            UserDefaults.standard.set(newPath, forKey: lastWallpaperPathKey)
            lastWallpaperPath = newPath
            print("[WallpaperEngineXBridge] Updated persisted path from \(oldPrefix) to \(newPrefix)")
        }
    }

    // MARK: - 二进制查找

    /// 解析 bundled `wallpaper-wgpu` 可执行文件路径
    nonisolated static func resolvedCLIExecutableURL() -> URL? {
        // 1. Bundle 内（folder reference 场景）
        if let url = Bundle.main.url(forResource: "wallpaper-wgpu", withExtension: nil) {
            print("[WallpaperEngineXBridge] 找到 wallpaper-wgpu: Bundle.main.url")
            return url
        }

        // 2. Contents/Resources/wallpaper-wgpu
        let bundleResources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/wallpaper-wgpu")
        if FileManager.default.fileExists(atPath: bundleResources.path) {
            print("[WallpaperEngineXBridge] 找到 wallpaper-wgpu: Contents/Resources")
            return bundleResources
        } else {
            print("[WallpaperEngineXBridge] 未找到: \(bundleResources.path)")
        }

        // 3. Contents/Resources/Resources/wallpaper-wgpu（folder reference 嵌套）
        let nestedResources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Resources/wallpaper-wgpu")
        if FileManager.default.fileExists(atPath: nestedResources.path) {
            print("[WallpaperEngineXBridge] 找到 wallpaper-wgpu: Resources/Resources")
            return nestedResources
        } else {
            print("[WallpaperEngineXBridge] 未找到: \(nestedResources.path)")
        }

        // 4. resourceURL
        if let resourceURL = Bundle.main.resourceURL {
            let resourcePath = resourceURL.appendingPathComponent("wallpaper-wgpu")
            if FileManager.default.fileExists(atPath: resourcePath.path) {
                print("[WallpaperEngineXBridge] 找到 wallpaper-wgpu: resourceURL")
                return resourcePath
            } else {
                print("[WallpaperEngineXBridge] 未找到: \(resourcePath.path)")
            }
        }

        // 5. bundle 同级目录（开发/调试）
        let siblingPath = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("wallpaper-wgpu")
        if FileManager.default.fileExists(atPath: siblingPath.path) {
            print("[WallpaperEngineXBridge] 找到 wallpaper-wgpu: bundle 同级")
            return siblingPath
        } else {
            print("[WallpaperEngineXBridge] 未找到: \(siblingPath.path)")
        }

        // 6. 项目开发路径
        let projectPaths = [
            ("/Volumes/mac/CodeLibrary/Claude/WallHaven/wallpaper-wgpu", "项目根目录"),
            ("/Volumes/mac/CodeLibrary/Claude/WallHaven/Resources/wallpaper-wgpu", "项目 Resources")
        ]
        for (path, label) in projectPaths {
            if FileManager.default.fileExists(atPath: path) {
                print("[WallpaperEngineXBridge] 找到 wallpaper-wgpu: \(label)")
                return URL(fileURLWithPath: path)
            } else {
                print("[WallpaperEngineXBridge] 未找到: \(path) (\(label))")
            }
        }

        print("[WallpaperEngineXBridge] ❌ wallpaper-wgpu 在所有路径中均未找到")
        return nil
    }

    // MARK: - 窗口确认

    /// 等待渲染窗口出现（`--wallpaper`/`--background` 已处理后台壁纸渲染，只需确认窗口存在）
    private func adoptRenderWindow(pid: pid_t) async {
        guard checkScreenCapturePermission() else {
            print("[WallpaperEngineXBridge] ⚠️ 无屏幕录制权限，跳过窗口确认（renderer 仍正常工作）")
            return
        }
        let timeout: TimeInterval = 10
        let pollInterval: TimeInterval = 0.3
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            if findWindowForProcess(pid: pid) != nil {
                print("[WallpaperEngineXBridge] ✅ 渲染窗口已确认")
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        print("[WallpaperEngineXBridge] ⚠️ 未找到渲染窗口（超时 \(timeout)s，renderer 仍会工作）")
    }

    /// 使用 CoreGraphics 查找指定进程的窗口，返回 CGWindowID
    /// ⚠️ 调用方需确保已有屏幕录制权限，否则 macOS 26 会 EXC_BREAKPOINT
    private func findWindowForProcess(pid: pid_t) -> CGWindowID? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int, ownerPID == pid else { continue }
            guard let windowID = window[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let width = Int(bounds["Width"] ?? 0)
            let height = Int(bounds["Height"] ?? 0)
            guard width >= 100, height >= 100 else { continue }
            return windowID
        }
        return nil
    }

    // MARK: - 首帧捕获（锁屏 / 静态 fallback）

    /// 壁纸路径的缓存 key，用于判断是否已捕过帧
    private static func frameCacheKey(for path: String) -> String {
        let hash = abs(path.hashValue)
        return "cached_frame_\(hash)"
    }

    /// 捕获首帧并设为静态桌面壁纸（锁屏显示 + wallpaper-wgpu 未运行时的 fallback）
    private func captureStaticFallbackFrame(path: String, expectedPID: pid_t? = nil) async -> Bool {
        // 权限检查（CGWindowListCreateImage 无权限时会 EXC_BREAKPOINT）
        guard checkScreenCapturePermission() else {
            print("[WallpaperEngineXBridge] ❌ 无屏幕录制权限，无法捕获真实首帧")
            return false
        }

        let cacheKey = Self.frameCacheKey(for: path)
        print("[WallpaperEngineXBridge] 每次设置 Scene 壁纸都重新捕获静态帧: \(cacheKey)")

        guard let pid = expectedPID ?? renderPID else { return false }
        guard expectedPID == nil || renderPID == expectedPID else { return false }

        // 查找渲染窗口
        guard let windowID = findWindowForProcess(pid: pid) else {
            print("[WallpaperEngineXBridge] ⚠️ 未找到渲染窗口，无法捕获真实首帧")
            return false
        }

        // 轮询等待非黑帧
        let minimumCaptureWarmup: TimeInterval = 8.0
        let timeout: TimeInterval = 25
        let pollInterval: TimeInterval = 0.5
        let startTime = Date()
        var lastFrame: CGImage?

        while Date().timeIntervalSince(startTime) < timeout {
            guard renderPID == pid, kill(pid, 0) == 0 else { return false } // 进程已退出或已切换

            if let image = captureWindowFrame(windowID: windowID) {
                // 至少等待更久让场景完成暗到亮的加载，避免缓存黑屏/暗场帧
                if Date().timeIntervalSince(startTime) >= minimumCaptureWarmup, isNonBlackFrame(image) {
                    // 找到有效帧，保存并设静态壁纸
                    return saveAndApplyStaticFrame(image, for: path, cacheKey: cacheKey)
                }
                lastFrame = image
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        // 超时：用最后一帧（即使可能偏黑）
        if let frame = lastFrame {
            print("[WallpaperEngineXBridge] ⚠️ 首帧捕获超时，使用最后一帧")
            return saveAndApplyStaticFrame(frame, for: path, cacheKey: cacheKey)
        } else {
            print("[WallpaperEngineXBridge] ❌ 首帧捕获失败（无任何帧）")
            return false
        }
    }

    /// 保存帧到缓存并设为静态壁纸
    private func saveAndApplyStaticFrame(_ image: CGImage, for path: String, cacheKey: String) -> Bool {
        // 保存到缓存目录
        let cacheDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.waifux.wallpaperengine/captured-frames")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let fileURL = cacheDir.appendingPathComponent("\(cacheKey).jpg")

        // 写入 JPEG
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            print("[WallpaperEngineXBridge] ⚠️ JPEG 编码失败")
            return false
        }
        do {
            try jpegData.write(to: fileURL)
            print("[WallpaperEngineXBridge] ✅ 首帧已保存: \(fileURL.path)")
        } catch {
            print("[WallpaperEngineXBridge] ⚠️ 首帧写入失败: \(error.localizedDescription)")
            return false
        }

        // 标记已缓存
        UserDefaults.standard.set(fileURL.path, forKey: cacheKey)

        if #available(macOS 26.0, *), VideoWallpaperManager.shared.isLockScreenEnabled {
            print("[WallpaperEngineXBridge] 🔒 动态锁屏已启用，跳过静态 fallback 壁纸设置以保护用户锁屏选择")
            return false
        }

        // 设为静态桌面壁纸（锁屏会跟随使用此壁纸）
        let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
            .fillColor: NSColor.black
        ]
        var didApply = false
        let screens = activeTargetScreens()
        for screen in screens.isEmpty ? NSScreen.screens : screens {
            do {
                try NSWorkspace.shared.setDesktopImageURLForAllSpaces(fileURL, for: screen, options: fillOptions)
                DesktopWallpaperSyncManager.shared.registerWallpaperSet(fileURL, for: screen, options: fillOptions)
                print("[WallpaperEngineXBridge] ✅ 静态 fallback 壁纸已设置 (screen: \(screen.localizedName))")
                didApply = true
            } catch {
                print("[WallpaperEngineXBridge] ⚠️ 设置静态壁纸失败 (screen: \(screen.localizedName)): \(error.localizedDescription)")
            }
        }
        return didApply
    }

    /// 使用 CoreGraphics 捕获窗口帧
    /// ⚠️ 调用方需确保已有屏幕录制权限，否则 macOS 26 会 EXC_BREAKPOINT
    private func captureWindowFrame(windowID: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(
            .infinite,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )
    }

    /// 判断帧是否为非黑的有效帧
    private func isNonBlackFrame(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return false }

        // 采样中心 1/4 区域
        let sampleRect = CGRect(
            x: width / 4,
            y: height / 4,
            width: width / 2,
            height: height / 2
        )
        guard let cropped = image.cropping(to: sampleRect) else { return false }
        guard let dataProvider = cropped.dataProvider else { return false }
        guard let pixelData = dataProvider.data else { return false }
        let data: UnsafePointer<UInt8> = CFDataGetBytePtr(pixelData)
        let bytesPerRow = cropped.bytesPerRow

        var totalBrightness: UInt64 = 0
        var pixelCount: UInt64 = 0

        for y in 0..<cropped.height {
            let rowOffset = y * bytesPerRow
            for x in 0..<cropped.width {
                let offset = rowOffset + x * 4
                let r = UInt64(data[offset + 1])
                let g = UInt64(data[offset + 2])
                let b = UInt64(data[offset + 3])
                totalBrightness += (r + g + b) / 3
                pixelCount += 1
            }
        }

        guard pixelCount > 0 else { return false }
        let avgBrightness = Double(totalBrightness) / Double(pixelCount)
        return avgBrightness > 10.0
    }

    // MARK: - 辅助方法

    private func activeTargetScreens() -> [NSScreen] {
        if targetScreenIDs.isEmpty && targetScreenFingerprints.isEmpty {
            return NSScreen.screens
        }
        relinkTargetScreens()
        return NSScreen.screens.filter { screen in
            targetScreenIDs.contains(screen.wallpaperScreenIdentifier) ||
            targetScreenFingerprints.contains(screen.wallpaperScreenFingerprint)
        }
    }

    private func relinkTargetScreens() {
        for screen in NSScreen.screens where targetScreenFingerprints.contains(screen.wallpaperScreenFingerprint) {
            targetScreenIDs.insert(screen.wallpaperScreenIdentifier)
        }
    }

    private func handleScreenParametersChanged() {
        guard isControllingExternalEngine else { return }
        guard !isSettingWallpaper else {
            print("[WallpaperEngineXBridge] 忽略屏幕参数通知：壁纸正在设置中")
            return
        }
        guard let path = lastWallpaperPath else { return }

        relinkTargetScreens()
        let currentConfigurations = currentTargetScreenConfigurations()
        guard currentConfigurations != lastAppliedScreenConfigurations else {
            print("[WallpaperEngineXBridge] 忽略屏幕参数通知：目标显示器配置未变化")
            return
        }

        screenChangeRestartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isControllingExternalEngine, !self.isSettingWallpaper else { return }
            self.relinkTargetScreens()
            guard self.currentTargetScreenConfigurations() != self.lastAppliedScreenConfigurations else {
                print("[WallpaperEngineXBridge] 跳过屏幕变化重启：目标显示器配置已恢复一致")
                return
            }

            let screens = self.activeTargetScreens()
            Task {
                print("[WallpaperEngineXBridge] 屏幕参数已变更，重启渲染进程")
                try? await self.setWallpaper(path: path, targetScreens: screens.isEmpty ? nil : screens)
            }
        }
        screenChangeRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func currentTargetScreenConfigurations() -> [ScreenConfigurationSignature] {
        activeTargetScreens()
            .map(ScreenConfigurationSignature.init(screen:))
            .sorted { lhs, rhs in
                lhs.screenID < rhs.screenID
            }
    }
}

// MARK: - Web 壁纸旧流程（WKWebView）

private func isWebWallpaper(path: String) -> Bool {
    detectWallpaperProjectType(path: path)?.lowercased() == "web"
}

private func detectWallpaperProjectType(path: String) -> String? {
    let fm = FileManager.default
    let url = URL(fileURLWithPath: path)
    let contentDir: URL

    if url.pathExtension.lowercased() == "pkg" {
        guard let extracted = extractPKG(at: url) else { return nil }
        contentDir = extracted
    } else {
        contentDir = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
    }

    let projectJSON = contentDir.appendingPathComponent("project.json")
    if fm.fileExists(atPath: projectJSON.path),
       let data = try? Data(contentsOf: projectJSON),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let type = json["type"] as? String, !type.isEmpty {
            return type
        }
        if json["preset"] != nil {
            return "web"
        }
        if let file = json["file"] as? String {
            let ext = (file as NSString).pathExtension.lowercased()
            if ext == "html" || ext == "htm" { return "web" }
            if ext == "json", file.lowercased().contains("scene") { return "scene" }
            if ["mp4", "mov", "webm", "avi"].contains(ext) { return "video" }
        }
    }

    guard let entries = try? fm.contentsOfDirectory(at: contentDir, includingPropertiesForKeys: nil) else {
        return nil
    }
    let names = entries.map { $0.lastPathComponent.lowercased() }
    let exts = entries.map { $0.pathExtension.lowercased() }
    if exts.contains("html") || exts.contains("htm") { return "web" }
    if names.contains(where: { $0.hasSuffix(".scene.pkg") || $0 == "scene.pkg" }) { return "scene" }
    if exts.contains("mp4") || exts.contains("mov") || exts.contains("webm") { return "video" }
    if exts.contains("pkg") { return "scene" }
    return nil
}

private func extractPKG(at url: URL) -> URL? {
    let fm = FileManager.default
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wallpaperengine_pkg_\(url.deletingPathExtension().lastPathComponent)_\(UUID().uuidString.prefix(8))")
    try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-o", "-q", url.path, "-d", tempDir.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? tempDir : nil
    } catch {
        print("[WebRendererBridge] extractPKG failed: \(error.localizedDescription)")
        return nil
    }
}

private func steamWorkshopContentInstallRootIfApplicable(forProjectDir projectDir: URL) -> URL? {
    let comps = projectDir.standardizedFileURL.pathComponents
    guard let idx = comps.firstIndex(of: "431960"), idx + 1 < comps.count else {
        return nil
    }
    let prefix = comps.prefix(through: idx + 1)
    let path = "/" + prefix.dropFirst().joined(separator: "/")
    let url = URL(fileURLWithPath: path, isDirectory: true)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
        return nil
    }
    return url
}

private func webWallpaperFileReadAccessURL(projectContentDir: URL, wallpaperPath: String) -> URL {
    if wallpaperPath.contains("/steamapps/workshop/content/"),
       let root = steamWorkshopContentInstallRootIfApplicable(forProjectDir: projectContentDir) {
        return root
    }
    return projectContentDir
}

private func resolveWallpaperDependencyPath(from contentDir: URL, dependencyID: String) -> URL? {
    let fm = FileManager.default
    let sibling = contentDir.deletingLastPathComponent().appendingPathComponent(dependencyID)
    if fm.fileExists(atPath: sibling.path) { return sibling }

    var current = contentDir
    for _ in 0..<6 {
        current = current.deletingLastPathComponent()
        let candidate = current.appendingPathComponent("steamapps/workshop/content/431960/\(dependencyID)")
        if fm.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
}

private func mergeWallpaperWithDependency(contentDir: URL, dependencyDir: URL) -> URL? {
    let fm = FileManager.default
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wallpaperengine_merged_\(contentDir.lastPathComponent)_\(dependencyDir.lastPathComponent)_\(UUID().uuidString.prefix(8))")
    do {
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        if let depEntries = try? fm.contentsOfDirectory(at: dependencyDir, includingPropertiesForKeys: nil) {
            for entry in depEntries {
                let dest = tempDir.appendingPathComponent(entry.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.copyItem(at: entry, to: dest)
                }
            }
        }
        if let entries = try? fm.contentsOfDirectory(at: contentDir, includingPropertiesForKeys: nil) {
            for entry in entries {
                let dest = tempDir.appendingPathComponent(entry.lastPathComponent)
                if fm.fileExists(atPath: dest.path) {
                    try? fm.removeItem(at: dest)
                }
                try? fm.copyItem(at: entry, to: dest)
            }
        }
        return tempDir
    } catch {
        print("[WebRendererBridge] dependency merge failed: \(error.localizedDescription)")
        return nil
    }
}

private func resolveWebWallpaperEntry(path: String) -> (baseURL: URL, indexFile: String)? {
    let url = URL(fileURLWithPath: path)
    let contentDir: URL
    if url.pathExtension.lowercased() == "pkg" {
        guard let extracted = extractPKG(at: url) else { return nil }
        contentDir = extracted
    } else {
        contentDir = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
    }

    let projectJSON = contentDir.appendingPathComponent("project.json")
    guard FileManager.default.fileExists(atPath: projectJSON.path),
          let data = try? Data(contentsOf: projectJSON),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        if url.pathExtension.lowercased() == "html" || url.pathExtension.lowercased() == "htm" {
            return (url.deletingLastPathComponent(), url.lastPathComponent)
        }
        let index = contentDir.appendingPathComponent("index.html")
        return FileManager.default.fileExists(atPath: index.path) ? (contentDir, "index.html") : nil
    }

    let file = json["file"] as? String ?? "index.html"
    if let dependency = json["dependency"] as? String, !dependency.isEmpty,
       let depDir = resolveWallpaperDependencyPath(from: contentDir, dependencyID: dependency),
       let merged = mergeWallpaperWithDependency(contentDir: contentDir, dependencyDir: depDir) {
        if FileManager.default.fileExists(atPath: merged.appendingPathComponent(file).path) {
            return (merged, file)
        }
        if FileManager.default.fileExists(atPath: merged.appendingPathComponent("index.html").path) {
            return (merged, "index.html")
        }
        try? FileManager.default.removeItem(at: merged)
    }

    if FileManager.default.fileExists(atPath: contentDir.appendingPathComponent(file).path) {
        return (contentDir, file)
    }
    if FileManager.default.fileExists(atPath: contentDir.appendingPathComponent("index.html").path) {
        return (contentDir, "index.html")
    }
    return nil
}

private func readWebWallpaperUserPropertiesJSON(contentDir: URL) -> String? {
    let projectURL = contentDir.appendingPathComponent("project.json")
    guard let data = try? Data(contentsOf: projectURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let general = json["general"] as? [String: Any],
          let props = general["properties"] as? [String: Any],
          !props.isEmpty,
          let out = try? JSONSerialization.data(withJSONObject: props, options: []),
          let str = String(data: out, encoding: .utf8) else {
        return nil
    }
    return str
}

private final class WebRendererBridge: NSObject, WKNavigationDelegate {
    static let shared = WebRendererBridge()

    private struct WebInteractionEvent: @unchecked Sendable {
        let type: String
        let screenX: Double
        let screenY: Double
        let button: Int
        let buttons: Int
        let clickCount: Int
        let deltaX: Double
        let deltaY: Double
        let key: String
        let code: String
        let keyCode: Int
        let ctrlKey: Bool
        let altKey: Bool
        let shiftKey: Bool
        let metaKey: Bool
    }

    private static let wallpaperEngineWebAPIShim = WKUserScript(
        source: """
        (function() {
          try {
            window.wallpaperMediaIntegration = { playback: { PLAYING: 1, PAUSED: 2, STOPPED: 0 } };
            var __wxAudioCbs = [];
            var __wxAudioBuf = new Float32Array(128);
            window.wallpaperRegisterAudioListener = function(cb) {
              if (typeof cb === 'function') __wxAudioCbs.push(cb);
            };
            setInterval(function() {
              for (var j = 0; j < __wxAudioCbs.length; j++) {
                try { __wxAudioCbs[j](__wxAudioBuf); } catch (e) {}
              }
            }, 33);
            window.wallpaperRegisterMediaStatusListener = function(cb) {
              if (typeof cb === 'function') {
                try { cb({ enabled: false }); } catch (e) {}
              }
            };
            window.wallpaperRegisterMediaPropertiesListener = function(cb) {};
            window.wallpaperRegisterMediaThumbnailListener = function(cb) {};
            window.wallpaperRegisterMediaPlaybackListener = function(cb) {
              if (typeof cb === 'function') {
                try { cb({ state: window.wallpaperMediaIntegration.playback.STOPPED }); } catch (e) {}
              }
            };
            window.wallpaperRegisterMediaTimelineListener = function(cb) {};
          } catch (e) {}
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    private static let localFileCompatScript = WKUserScript(
        source: """
        (function() {
          try {
            if (location.protocol !== "file:") return;
            var proto = HTMLImageElement.prototype;
            var srcDesc = Object.getOwnPropertyDescriptor(proto, "src");
            if (srcDesc && srcDesc.set) {
              Object.defineProperty(proto, "src", {
                set: function(value) {
                  try {
                    var s = String(value || "");
                    if (s.indexOf("http:") !== 0 && s.indexOf("https:") !== 0 && s.indexOf("data:") !== 0 && s.indexOf("blob:") !== 0) {
                      this.removeAttribute("crossorigin");
                    }
                  } catch (e) {}
                  srcDesc.set.call(this, value);
                },
                get: srcDesc.get,
                configurable: true
              });
            }
            var origFetch = window.fetch;
            if (typeof origFetch === "function") {
              window.fetch = function(input, init) {
                var url = typeof input === "string" ? input : (input && input.url) ? input.url : "";
                if (url && url.indexOf("http:") !== 0 && url.indexOf("https:") !== 0 && url.indexOf("data:") !== 0 && url.indexOf("blob:") !== 0) {
                  return new Promise(function(resolve, reject) {
                    var xhr = new XMLHttpRequest();
                    xhr.open("GET", url, true);
                    xhr.onload = function() {
                      if (xhr.status === 200 || xhr.status === 0) {
                        resolve(new Response(xhr.responseText, { status: 200, statusText: "OK" }));
                      } else {
                        reject(new Error("HTTP " + xhr.status));
                      }
                    };
                    xhr.onerror = function() { reject(new Error("network error")); };
                    xhr.send();
                  });
                }
                return origFetch.call(this, input, init);
              };
            }
          } catch (e) {}
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    private static let interactionBridgeScript = WKUserScript(
        source: """
        (function() {
          if (window.__waifuXDispatchInput) return;
          function targetAt(x, y) {
            return document.elementFromPoint(x, y) || document.body || document.documentElement || document;
          }
          function mouseInit(e) {
            return {
              bubbles: true,
              cancelable: true,
              composed: true,
              view: window,
              clientX: e.x || 0,
              clientY: e.y || 0,
              screenX: e.screenX || 0,
              screenY: e.screenY || 0,
              button: e.button || 0,
              buttons: e.buttons || 0,
              ctrlKey: !!e.ctrlKey,
              altKey: !!e.altKey,
              shiftKey: !!e.shiftKey,
              metaKey: !!e.metaKey
            };
          }
          function firePointer(target, type, init) {
            try {
              if (window.PointerEvent) {
                target.dispatchEvent(new PointerEvent(type, Object.assign({}, init, {
                  pointerId: 1,
                  pointerType: "mouse",
                  isPrimary: true
                })));
              }
            } catch (e) {}
          }
          window.__waifuXDispatchInput = function(e) {
            try {
              if (!e || !e.type) return;
              if (e.type === "keydown" || e.type === "keyup") {
                var keyTarget = document.activeElement || document.body || document.documentElement || document;
                var keyInit = {
                  bubbles: true,
                  cancelable: true,
                  composed: true,
                  key: e.key || "",
                  code: e.code || "",
                  keyCode: e.keyCode || 0,
                  which: e.keyCode || 0,
                  ctrlKey: !!e.ctrlKey,
                  altKey: !!e.altKey,
                  shiftKey: !!e.shiftKey,
                  metaKey: !!e.metaKey
                };
                keyTarget.dispatchEvent(new KeyboardEvent(e.type, keyInit));
                if (keyTarget !== window) window.dispatchEvent(new KeyboardEvent(e.type, keyInit));
                return;
              }

              var target = targetAt(e.x || 0, e.y || 0);
              var init = mouseInit(e);
              if (e.type === "wheel") {
                target.dispatchEvent(new WheelEvent("wheel", Object.assign({}, init, {
                  deltaX: e.deltaX || 0,
                  deltaY: e.deltaY || 0,
                  deltaMode: 0
                })));
                return;
              }

              var pointerType = {
                mousemove: "pointermove",
                mousedown: "pointerdown",
                mouseup: "pointerup"
              }[e.type];
              if (pointerType) firePointer(target, pointerType, init);
              target.dispatchEvent(new MouseEvent(e.type, init));
              if (e.type === "mouseup") {
                target.dispatchEvent(new MouseEvent("click", init));
                if ((e.clickCount || 0) >= 2) {
                  target.dispatchEvent(new MouseEvent("dblclick", init));
                }
              }
            } catch (err) {}
          };
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    private var window: NSWindow?
    private var webView: WKWebView?
    private var pendingCompletion: ((Bool) -> Void)?
    private var extractedPKGDir: URL?
    private var mergedDependencyDir: URL?
    private var injectedPropertiesJSON: String?
    private var firstFrameSettleGeneration: UInt64 = 0
    private var currentScreenIndex: Int?
    private var desktopCaptureSlot = 0
    private var interactionMonitors: [Any] = []
    private(set) var isLoaded = false

    private enum FirstFramePolicy {
        static let minElapsed: TimeInterval = 6.0
        static let maxElapsed: TimeInterval = 24
        static let pollInterval: TimeInterval = 0.5
        static let diffThreshold: Double = 0.014
        static let stablePassesRequired: Int = 2
        static let thumbDimension: Int = 48
    }

    func loadWallpaper(path: String, width: Int, height: Int, screen: Int? = nil, completion: ((Bool) -> Void)? = nil) {
        stop()
        pendingCompletion = completion
        injectedPropertiesJSON = nil
        currentScreenIndex = screen

        guard let (baseURL, indexFile) = resolveWebWallpaperEntry(path: path) else {
            print("[WebRendererBridge] 无法解析 Web 壁纸入口: \(path)")
            completion?(false)
            return
        }

        injectedPropertiesJSON = readWebWallpaperUserPropertiesJSON(contentDir: baseURL)
        if URL(fileURLWithPath: path).pathExtension.lowercased() == "pkg" {
            extractedPKGDir = baseURL
        } else if baseURL.path.contains("wallpaperengine_merged_") {
            mergedDependencyDir = baseURL
        }

        let screens = NSScreen.screens
        let targetScreen: NSScreen
        if let s = screen, screens.indices.contains(s) {
            targetScreen = screens[s]
        } else if let main = NSScreen.main {
            targetScreen = main
        } else if let first = screens.first {
            targetScreen = first
        } else {
            completion?(false)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.setFrame(targetScreen.frame, display: true)
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        if #available(macOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        let ucc = WKUserContentController()
        ucc.addUserScript(Self.wallpaperEngineWebAPIShim)
        ucc.addUserScript(Self.localFileCompatScript)
        ucc.addUserScript(Self.interactionBridgeScript)
        config.userContentController = ucc

        let webView = WKWebView(frame: window.contentView?.bounds ?? .zero, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView?.addSubview(webView)

        self.window = window
        self.webView = webView
        startInteractionBridge()

        let fileURL = baseURL.appendingPathComponent(indexFile)
        let readAccessURL = webWallpaperFileReadAccessURL(projectContentDir: baseURL, wallpaperPath: path)
        autoFixSpineConfigIfNeeded(projectContentDir: baseURL)
        webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        window.orderBack(nil)

        let generation = firstFrameSettleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.firstFrameSettleGeneration == generation, self.pendingCompletion != nil else { return }
            print("[WebRendererBridge] Web 壁纸加载超时: \(path)")
            self.pendingCompletion?(false)
            self.pendingCompletion = nil
        }
    }

    private func autoFixSpineConfigIfNeeded(projectContentDir: URL) {
        let fm = FileManager.default
        let imageDir = projectContentDir.appendingPathComponent("image")
        let configURL = imageDir.appendingPathComponent(".config.json")
        guard fm.fileExists(atPath: imageDir.path),
              !fm.fileExists(atPath: configURL.path),
              let skelFiles = try? fm.contentsOfDirectory(at: imageDir, includingPropertiesForKeys: [.fileSizeKey])
                .filter({ $0.pathExtension.lowercased() == "skel" }),
              !skelFiles.isEmpty else { return }

        let targetSkel = skelFiles.max { a, b in
            let sizeA = (try? fm.attributesOfItem(atPath: a.path)[.size] as? Int) ?? 0
            let sizeB = (try? fm.attributesOfItem(atPath: b.path)[.size] as? Int) ?? 0
            return sizeA < sizeB
        } ?? skelFiles[0]
        let config: [String: String] = ["skeleton": targetSkel.lastPathComponent]
        if let data = try? JSONSerialization.data(withJSONObject: config, options: []) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        runWebWallpaperBootstrap { [weak self] in
            self?.beginSettlingFirstFrame()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(success: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(success: false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoaded = false
        finishLoad(success: false)
    }

    func pause() {
        window?.orderOut(nil)
        webView?.evaluateJavaScript("""
            document.querySelectorAll('video, audio').forEach(m => m.pause());
            document.querySelectorAll('*').forEach(el => {
                const st = window.getComputedStyle(el);
                if (st.animationName !== 'none') el.style.animationPlayState = 'paused';
            });
        """) { _, _ in }
    }

    func resume() {
        guard isLoaded else { return }
        window?.orderBack(nil)
        webView?.evaluateJavaScript("""
            document.querySelectorAll('video, audio').forEach(m => { if(m.paused) m.play().catch(()=>{}); });
            document.querySelectorAll('*').forEach(el => {
                if (el.style.animationPlayState === 'paused') el.style.animationPlayState = 'running';
            });
            window.dispatchEvent(new Event('resize'));
        """) { _, _ in }
    }

    func stop() {
        firstFrameSettleGeneration += 1
        pendingCompletion = nil
        stopInteractionBridge()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        window?.close()
        window = nil
        isLoaded = false
        currentScreenIndex = nil
        if let dir = extractedPKGDir {
            try? FileManager.default.removeItem(at: dir)
            extractedPKGDir = nil
        }
        if let dir = mergedDependencyDir {
            try? FileManager.default.removeItem(at: dir)
            mergedDependencyDir = nil
        }
        injectedPropertiesJSON = nil
    }

    private func startInteractionBridge() {
        stopInteractionBridge()
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel,
            .keyDown,
            .keyUp
        ]

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let payload = Self.webInteractionEvent(from: event) else { return }
            Task { @MainActor [weak self] in
                self?.dispatchInteractionEvent(payload)
            }
        }) {
            interactionMonitors.append(globalMonitor)
        }

        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let payload = Self.webInteractionEvent(from: event) else { return event }
            Task { @MainActor [weak self] in
                self?.dispatchInteractionEvent(payload)
            }
            return event
        }
        if let localMonitor {
            interactionMonitors.append(localMonitor)
        }
    }

    private func stopInteractionBridge() {
        for monitor in interactionMonitors {
            NSEvent.removeMonitor(monitor)
        }
        interactionMonitors.removeAll()
    }

    private static func webInteractionEvent(from event: NSEvent) -> WebInteractionEvent? {
        let type: String
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            type = "mousemove"
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            type = "mousedown"
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            type = "mouseup"
        case .scrollWheel:
            type = "wheel"
        case .keyDown:
            type = "keydown"
        case .keyUp:
            type = "keyup"
        default:
            return nil
        }

        let flags = event.modifierFlags
        let key = event.charactersIgnoringModifiers ?? event.characters ?? ""
        let location = NSEvent.mouseLocation
        let isRightButton = event.type == .rightMouseDown || event.type == .rightMouseUp || event.type == .rightMouseDragged
        let button = isRightButton ? 2 : (event.buttonNumber == 0 ? 0 : Int(event.buttonNumber))
        let buttons: Int
        switch event.type {
        case .leftMouseDown, .leftMouseDragged:
            buttons = 1
        case .rightMouseDown, .rightMouseDragged:
            buttons = 2
        case .otherMouseDown, .otherMouseDragged:
            buttons = 4
        default:
            buttons = 0
        }

        return WebInteractionEvent(
            type: type,
            screenX: Double(location.x),
            screenY: Double(location.y),
            button: button,
            buttons: buttons,
            clickCount: max(1, event.clickCount),
            deltaX: Double(event.scrollingDeltaX),
            deltaY: Double(event.scrollingDeltaY),
            key: key,
            code: Self.domCode(for: event),
            keyCode: Self.domKeyCode(for: event),
            ctrlKey: flags.contains(.control),
            altKey: flags.contains(.option),
            shiftKey: flags.contains(.shift),
            metaKey: flags.contains(.command)
        )
    }

    private static func domCode(for event: NSEvent) -> String {
        if let scalar = (event.charactersIgnoringModifiers ?? event.characters)?.unicodeScalars.first {
            if scalar.value >= 65 && scalar.value <= 90 {
                return "Key\(Character(scalar))"
            }
            if scalar.value >= 97 && scalar.value <= 122,
               let upper = UnicodeScalar(scalar.value - 32) {
                return "Key\(Character(upper))"
            }
            if scalar.value >= 48 && scalar.value <= 57 {
                return "Digit\(Character(scalar))"
            }
        }
        switch event.keyCode {
        case 36: return "Enter"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Backspace"
        case 53: return "Escape"
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        default: return "Unidentified"
        }
    }

    private static func domKeyCode(for event: NSEvent) -> Int {
        switch event.keyCode {
        case 36: return 13
        case 48: return 9
        case 49: return 32
        case 51: return 8
        case 53: return 27
        case 123: return 37
        case 124: return 39
        case 125: return 40
        case 126: return 38
        default:
            if let scalar = (event.charactersIgnoringModifiers ?? event.characters)?.unicodeScalars.first {
                return Int(scalar.value)
            }
            return Int(event.keyCode)
        }
    }

    private func dispatchInteractionEvent(_ event: WebInteractionEvent) {
        guard let webView, let window else { return }
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return }

        let screenPoint = CGPoint(x: CGFloat(event.screenX), y: CGFloat(event.screenY))
        guard frame.contains(screenPoint) || event.type == "keyup" else { return }

        let xInWindow = screenPoint.x - frame.minX
        let yInWindow = screenPoint.y - frame.minY
        let xScale = Double(webView.bounds.width / frame.width)
        let yScale = Double(webView.bounds.height / frame.height)
        let x = max(0, min(Double(webView.bounds.width), Double(xInWindow) * xScale))
        let y = max(0, min(Double(webView.bounds.height), (Double(frame.height) - Double(yInWindow)) * yScale))

        let payload: [String: Any] = [
            "type": event.type,
            "x": x,
            "y": y,
            "screenX": event.screenX,
            "screenY": event.screenY,
            "button": event.button,
            "buttons": event.buttons,
            "clickCount": event.clickCount,
            "deltaX": event.deltaX,
            "deltaY": event.deltaY,
            "key": event.key,
            "code": event.code,
            "keyCode": event.keyCode,
            "ctrlKey": event.ctrlKey,
            "altKey": event.altKey,
            "shiftKey": event.shiftKey,
            "metaKey": event.metaKey
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }

        webView.evaluateJavaScript("window.__waifuXDispatchInput && window.__waifuXDispatchInput(\(json));") { _, _ in }
    }

    private func runWebWallpaperBootstrap(completion: (() -> Void)? = nil) {
        var propsBlock = ""
        if let json = injectedPropertiesJSON,
           let data = json.data(using: .utf8) {
            let b64 = data.base64EncodedString()
            propsBlock = """
            try {
              var props = JSON.parse(atob("\(b64)"));
              if (window.wallpaperPropertyListener && typeof window.wallpaperPropertyListener.applyUserProperties === 'function') {
                window.wallpaperPropertyListener.applyUserProperties(props);
              }
            } catch(e) {}
            """
        }
        let source = """
        (function(){
          \(propsBlock)
          try {
            if (window.wallpaperPropertyListener && typeof window.wallpaperPropertyListener.applyGeneralProperties === 'function') {
              window.wallpaperPropertyListener.applyGeneralProperties({ fps: { value: 30, type: 'slider' } });
            }
            document.documentElement.style.cssText = 'width:100%;height:100%;margin:0;padding:0;background:transparent;overflow:hidden;';
            document.body.style.setProperty('background-image', 'none', 'important');
            document.body.style.setProperty('width', '100%');
            document.body.style.setProperty('height', '100%');
            document.body.style.setProperty('margin', '0');
            document.body.style.setProperty('overflow', 'hidden');
            var pc = document.getElementById('player-container');
            if (pc) { pc.style.width = '100%'; pc.style.height = '100%'; }
            window.dispatchEvent(new Event('resize'));
          } catch(e) {}
          return true;
        })();
        """
        webView?.evaluateJavaScript(source) { _, _ in
            DispatchQueue.main.async { completion?() }
        }
    }

    private func beginSettlingFirstFrame() {
        firstFrameSettleGeneration += 1
        let generation = firstFrameSettleGeneration
        let start = Date()

        final class SettleState {
            var lastThumb: [UInt8]?
            var stablePasses = 0
            var lastImage: NSImage?
        }
        let state = SettleState()

        func scheduleStep() {
            guard generation == firstFrameSettleGeneration, webView != nil else { return }
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= FirstFramePolicy.maxElapsed {
                finishFirstFrame(state.lastImage)
                return
            }

            snapshotWebView { [weak self] image in
                guard let self, generation == self.firstFrameSettleGeneration else { return }
                guard let image else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + FirstFramePolicy.pollInterval) { scheduleStep() }
                    return
                }
                state.lastImage = image
                let thumb = self.grayscaleThumb(from: image, dimension: FirstFramePolicy.thumbDimension)
                defer { if let thumb { state.lastThumb = thumb } }
                if let prev = state.lastThumb, let curr = thumb {
                    let diff = Self.meanAbsDiffGrayscale(prev, curr)
                    if diff < FirstFramePolicy.diffThreshold, elapsed >= FirstFramePolicy.minElapsed {
                        state.stablePasses += 1
                    } else {
                        state.stablePasses = 0
                    }
                    if state.stablePasses >= FirstFramePolicy.stablePassesRequired {
                        finishFirstFrame(image)
                        return
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + FirstFramePolicy.pollInterval) { scheduleStep() }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { scheduleStep() }
    }

    private func snapshotWebView(completion: @escaping (NSImage?) -> Void) {
        guard let webView else {
            completion(nil)
            return
        }
        if #available(macOS 11.0, *) {
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: webView.bounds.size)
            webView.takeSnapshot(with: config) { image, _ in
                DispatchQueue.main.async { completion(image) }
            }
        } else {
            completion(nil)
        }
    }

    private func finishFirstFrame(_ image: NSImage?) {
        let success = image.flatMap { saveImage($0) } ?? false
        if success {
            applyCaptureAsDesktopWallpaper()
        }
        finishLoad(success: success || isLoaded)
    }

    private func finishLoad(success: Bool) {
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil
        completion(success)
    }

    private func grayscaleThumb(from image: NSImage, dimension: Int) -> [UInt8]? {
        guard dimension > 0 else { return nil }
        let target = NSSize(width: dimension, height: dimension)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: dimension,
            pixelsHigh: dimension,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.set()
        NSRect(origin: .zero, size: target).fill()
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.low]
        )
        NSGraphicsContext.restoreGraphicsState()
        var out = [UInt8](repeating: 0, count: dimension * dimension)
        for y in 0..<dimension {
            for x in 0..<dimension {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let g = UInt8(min(255, max(0, (c.redComponent * 0.299 + c.greenComponent * 0.587 + c.blueComponent * 0.114) * 255.0)))
                out[y * dimension + x] = g
            }
        }
        return out
    }

    private static func meanAbsDiffGrayscale(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var sum = 0
        for i in 0..<a.count {
            sum += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(sum) / Double(a.count * 255)
    }

    private func saveImage(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: webPrimaryCapturePath), options: .atomic)
            return true
        } catch {
            print("[WebRendererBridge] 首帧保存失败: \(error.localizedDescription)")
            return false
        }
    }

    private func applyCaptureAsDesktopWallpaper() {
        guard FileManager.default.fileExists(atPath: webPrimaryCapturePath) else { return }
        if #available(macOS 26.0, *), VideoWallpaperManager.shared.isLockScreenEnabled {
            print("[WebRendererBridge] 🔒 动态锁屏已启用，跳过 Web 捕获静态桌面写入")
            return
        }

        desktopCaptureSlot = 1 - desktopCaptureSlot
        let dstPath = desktopCaptureSlot == 0 ? webDeskCapturePath0 : webDeskCapturePath1
        let src = URL(fileURLWithPath: webPrimaryCapturePath)
        let dst = URL(fileURLWithPath: dstPath)
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.copyItem(at: src, to: dst)) != nil else { return }

        let screens: [NSScreen]
        if let idx = currentScreenIndex, NSScreen.screens.indices.contains(idx) {
            screens = [NSScreen.screens[idx]]
        } else {
            screens = NSScreen.screens
        }
        for screen in screens {
            try? NSWorkspace.shared.setDesktopImageURLForAllSpaces(dst, for: screen, options: [
                .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                .allowClipping: true
            ])
            DesktopWallpaperSyncManager.shared.registerWallpaperSet(dst, for: screen)
        }
    }
}

// MARK: - 错误类型

enum WallpaperEngineError: LocalizedError {
    case notInstalled
    case cliNotFound
    case screenCaptureDenied
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Wallpaper Engine 未安装"
        case .cliNotFound: return "未找到 wallpaper-wgpu 二进制文件"
        case .screenCaptureDenied: return "屏幕录制权限被拒绝，请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许本应用后重试"
        case .executionFailed(let msg): return msg
        }
    }
}
