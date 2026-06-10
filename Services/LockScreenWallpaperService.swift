//  LockScreenWallpaperService.swift
//  WaifuX
//
//  管理锁屏镜像实例的共享状态与偏好同步。
//  仅在 macOS 26.0+ 生效，通过 WallpaperExtensionKit 私有框架实现。
//
//  支持多显示器：每个显示器可以部署不同的视频，扩展根据 choiceConfiguration 选择对应视频。

import AVFoundation
import Foundation
import AppKit
import ImageIO
import notify

/// 锁屏镜像实例管理服务
///
/// 真实业务模型是：
/// 1. 扩展为每个显示器暴露一个固定的锁屏实例，用户在系统设置中手动选择一次
/// 2. 主 App 维护“显示器 -> 当前桌面视频源”映射
/// 3. 实例激活后，主 App 仅向对应显示器实例推送桌面帧，不自动切换系统壁纸选择
@MainActor
final class LockScreenWallpaperService {
    static let shared = LockScreenWallpaperService()

    struct DisplayInstance: Codable, Sendable {
        let id: String
        let displayID: UInt32
        let name: String
        let thumbnailPath: String?
    }

    /// 功能是否可用（macOS 26.0+ 且已配置 App Group）
    var isAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return sharedContainerURL != nil
    }

    /// 当前写入共享容器的镜像帧源路径
    private(set) var currentMirroringSourcePath: String?

    /// 已写入共享容器的视频 ID 集合（兼容旧缓存清理）
    private var deployedVideoIDs: Set<String> = []

    private let appGroupID = "group.com.waifux.app"
    private let prefsFileName = "waifux-wallpaper-prefs.json"
    private let videoDirName = "WallpaperVideos"
    private let imageDirName = "WallpaperImages"
    private let displayInstancesFileName = "waifux-display-instances.json"

    private var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private init() {}

    var displayInstancesURL: URL? {
        sharedContainerURL?.appendingPathComponent(displayInstancesFileName)
    }

    // MARK: - Public API

    /// 将指定桌面视频源写入共享容器，供锁屏实例在需要时读取缩略图/兜底内容。
    /// - Parameters:
    ///   - videoURL: 本地视频文件路径（MP4/MOV）
    ///   - videoID: 壁纸唯一标识（用于区分不同壁纸）
    func cacheMirroringSource(videoURL: URL, videoID: String, notify: Bool = true) async throws {
        guard isAvailable else {
            print("[LockScreenWallpaper] 功能不可用（需 macOS 26+）")
            return
        }

        guard UserDefaults.standard.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else {
            print("[LockScreenWallpaper] 动态锁屏已关闭，跳过")
            return
        }

        guard videoURL.isFileURL, FileManager.default.fileExists(atPath: videoURL.path) else {
            throw LockScreenError.fileNotFound
        }

        guard let container = sharedContainerURL else {
            throw LockScreenError.appGroupNotAvailable
        }

        let videoDir = container.appendingPathComponent(videoDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)

        // 清理不再需要的旧视频（保留当前部署的和新视频）
        var keepIDs = deployedVideoIDs
        keepIDs.insert(videoID)
        cleanupOldVideos(in: videoDir, keeping: keepIDs)

        // 用 hard link 将视频放到共享容器（同一卷不占额外空间）
        let destURL = videoDir.appendingPathComponent("\(videoID).mp4")
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        do {
            try FileManager.default.linkItem(at: videoURL, to: destURL)
        } catch {
            try FileManager.default.copyItem(at: videoURL, to: destURL)
        }

        deployedVideoIDs.insert(videoID)

        // 写入偏好设置
        let prefs = PrefsFile(
            userPaused: false,
            alwaysPauseDesktop: false,
            currentVideoPath: destURL.path,
            currentImagePath: nil,
            currentRealtimeSourceKind: nil
        )
        let prefsURL = container.appendingPathComponent(prefsFileName)
        let data = try JSONEncoder().encode(prefs)
        try data.write(to: prefsURL, options: .atomic)

        currentMirroringSourcePath = destURL.path

        // 先生成缩略图，再同步实例目录，确保封面路径在新目录中立即生效
        generateThumbnail(for: destURL, videoID: videoID)
        // 更新显示器实例目录（此时缩略图已就绪，posterThumbnailPath 能查到最新文件）
        syncInstanceCatalogToSocketServer(notify: notify)
        WallpaperExtensionSocketServer.shared.registerLocalDecodeVideo(videoID: videoID, videoURL: destURL)

        // 再通知 Extension 刷新（此时 SocketServer 已有最新数据）
        if notify {
            notifyExtensionPrefsChanged()
        }

        print("[LockScreenWallpaper] ✅ 已更新锁屏镜像帧源缓存: \(destURL.lastPathComponent)")
    }

    /// 将静态图片写入共享容器，并绑定到每个显示器实例。
    /// 静态壁纸不再退回系统锁屏选择写入；扩展直接渲染这里部署的图片。
    func cacheStaticImageSource(imageURL: URL, displayIDs: [UInt32]) async throws {
        guard isAvailable else {
            print("[LockScreenWallpaper] 功能不可用（需 macOS 26+）")
            return
        }

        guard UserDefaults.standard.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else {
            print("[LockScreenWallpaper] 动态锁屏已关闭，跳过静态图同步")
            return
        }

        guard let container = sharedContainerURL else {
            throw LockScreenError.appGroupNotAvailable
        }

        let imageData: Data
        if imageURL.isFileURL {
            guard FileManager.default.fileExists(atPath: imageURL.path) else {
                throw LockScreenError.fileNotFound
            }
            imageData = try Data(contentsOf: imageURL)
        } else {
            let (data, _) = try await URLSession.shared.data(from: imageURL)
            imageData = data
        }

        let imageDir = container.appendingPathComponent(imageDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)

        let ext = normalizedImageExtension(from: imageURL)
        var lastPath: String?
        for displayID in displayIDs {
            let sourceID = Self.displayInstanceID(displayID)
            let destURL = imageDir.appendingPathComponent("\(sourceID).\(ext)")
            cleanupCachedImages(sourceID: sourceID, in: imageDir)
            try imageData.write(to: destURL, options: .atomic)
            writeThumbnail(imageData: imageData, thumbnailID: sourceID)
            WallpaperExtensionSocketServer.shared.registerLocalDecodeVideo(videoID: sourceID, videoURL: destURL)
            WallpaperExtensionSocketServer.shared.enqueueCommand(
                IPCCommand(action: "switch_image", videoID: sourceID, displayID: displayID)
            )
            lastPath = destURL.path
            print("[LockScreenWallpaper] 🖼️ 已部署静态图 display=\(displayID) source=\(destURL.lastPathComponent)")
        }

        if let lastPath {
            let prefs = PrefsFile(
                userPaused: false,
                alwaysPauseDesktop: false,
                currentVideoPath: nil,
                currentImagePath: lastPath,
                currentRealtimeSourceKind: nil
            )
            let prefsURL = container.appendingPathComponent(prefsFileName)
            let data = try JSONEncoder().encode(prefs)
            try data.write(to: prefsURL, options: .atomic)
            currentMirroringSourcePath = lastPath
        }

        syncInstanceCatalogToSocketServer()
        notifyExtensionPrefsChanged()
    }

    /// 让已激活的锁屏实例切换到当前桌面视频。扩展侧本地解码该视频，不再等待 App 逐帧推送。
    /// 让已激活的锁屏实例切换到当前桌面视频。扩展侧本地解码该视频，不再等待 App 逐帧推送。
    /// - Parameter generation: 视频同步世代号，用于丢弃过期 Task 的命令。
    func switchActiveInstancesToLocalDecode(videoURL: URL, videoID: String, displayIDs: [UInt32], generation: UInt64 = 0) async {
        // 快速检查：如果世代已过期，跳过整个流程
        guard generation == 0 || WallpaperExtensionSocketServer.isCurrentGeneration(generation) else {
            print("[LockScreenWallpaper] ⏭️ switchActiveInstancesToLocalDecode 跳过过期世代 (gen=\(generation)) display=\(displayIDs)")
            return
        }

        do {
            try await cacheMirroringSource(videoURL: videoURL, videoID: videoID, notify: false)
        } catch {
            print("[LockScreenWallpaper] ❌ 本地解码视频缓存失败: \(error.localizedDescription)")
            return
        }

        copyVideoThumbnailToDisplayThumbnails(videoID: videoID, displayIDs: displayIDs)
        syncInstanceCatalogToSocketServer(notify: false)

        // 再次检查世代（file I/O 期间可能又有新切换）
        guard generation == 0 || WallpaperExtensionSocketServer.isCurrentGeneration(generation) else {
            print("[LockScreenWallpaper] ⏭️ switchActiveInstancesToLocalDecode 跳过过期命令 (gen=\(generation)) display=\(displayIDs) video=\(videoID)")
            return
        }

        for displayID in displayIDs {
            WallpaperExtensionSocketServer.shared.enqueueCommand(
                IPCCommand(action: "switch_video", videoID: videoID, displayID: displayID),
                generation: generation
            )
        }
        notifyExtensionPrefsChanged()
        print("[LockScreenWallpaper] 🔁 已请求扩展自解码切换 display=\(displayIDs) video=\(videoID) gen=\(generation)")
    }

    /// 清掉历史版本写入的实时帧源标记。当前 Web 锁屏只走静态图链路。
    func clearRealtimeSourceIfNeeded(notify: Bool = true) {
        guard isAvailable, let container = sharedContainerURL else { return }
        let prefsURL = container.appendingPathComponent(prefsFileName)
        guard let data = try? Data(contentsOf: prefsURL),
              var prefs = try? JSONDecoder().decode(PrefsFile.self, from: data),
              prefs.currentRealtimeSourceKind != nil else {
            return
        }
        prefs.currentRealtimeSourceKind = nil
        if let encoded = try? JSONEncoder().encode(prefs) {
            try? encoded.write(to: prefsURL, options: .atomic)
        }
        if notify {
            notifyExtensionPrefsChanged()
        }
        print("[LockScreenWallpaper] ✅ 已清理实时锁屏帧源标记")
    }

    /// 清空当前锁屏镜像帧源缓存。
    /// 不触碰用户在系统设置里手动选择的显示器实例。
    func clearMirroringSourceCache(notify: Bool = true) {
        guard isAvailable else { return }

        guard let container = sharedContainerURL else { return }

        // 清空视频目录
        let videoDir = container.appendingPathComponent(videoDirName, isDirectory: true)
        try? FileManager.default.removeItem(at: videoDir)
        let imageDir = container.appendingPathComponent(imageDirName, isDirectory: true)
        try? FileManager.default.removeItem(at: imageDir)

        // 更新偏好设置
        let prefs = PrefsFile(userPaused: false, alwaysPauseDesktop: false, currentVideoPath: nil, currentImagePath: nil, currentRealtimeSourceKind: nil)
        let prefsURL = container.appendingPathComponent(prefsFileName)
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: prefsURL, options: .atomic)
        }

        currentMirroringSourcePath = nil
        deployedVideoIDs.removeAll()
        if #available(macOS 26.0, *) {
            WallpaperExtensionSocketServer.shared.clearDisplayVideos()
        }

        if notify {
            notifyExtensionPrefsChanged()
        }

        print("[LockScreenWallpaper] ✅ 已清空锁屏镜像帧源缓存")
    }

    /// 暂停/恢复锁屏壁纸播放（用户手动控制）
    func setPaused(_ paused: Bool) {
        guard isAvailable else { return }
        guard let container = sharedContainerURL else { return }

        let prefsURL = container.appendingPathComponent(prefsFileName)
        var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
        prefs.userPaused = paused
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: prefsURL, options: .atomic)
        }
        notifyExtensionPrefsChanged()
    }

    /// 设置是否仅在锁屏时播放（桌面暂停）
    func setAlwaysPauseDesktop(_ pause: Bool) {
        guard isAvailable else { return }
        guard let container = sharedContainerURL else { return }

        let prefsURL = container.appendingPathComponent(prefsFileName)
        var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
        prefs.alwaysPauseDesktop = pause
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: prefsURL, options: .atomic)
        }
        notifyExtensionPrefsChanged()
    }

    /// 设置指定显示器的暂停状态（per-display pause）
    func setDisplayPaused(_ paused: Bool, forDisplayID displayID: UInt32) {
        guard isAvailable else { return }
        guard let container = sharedContainerURL else { return }

        let prefsURL = container.appendingPathComponent(prefsFileName)
        var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
        if paused {
            if prefs.pausedDisplayIDs == nil { prefs.pausedDisplayIDs = [] }
            prefs.pausedDisplayIDs?.insert(displayID)
        } else {
            prefs.pausedDisplayIDs?.remove(displayID)
        }
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: prefsURL, options: .atomic)
        }
        notifyExtensionPrefsChanged()
    }

    /// 查询指定显示器是否处于暂停状态
    func isDisplayPaused(_ displayID: UInt32) -> Bool {
        guard isAvailable else { return false }
        guard let container = sharedContainerURL else { return false }
        let prefsURL = container.appendingPathComponent(prefsFileName)
        guard let data = try? Data(contentsOf: prefsURL),
              let prefs = try? JSONDecoder().decode(PrefsFile.self, from: data) else { return false }
        return prefs.pausedDisplayIDs?.contains(displayID) ?? false
    }

    /// 设置指定显示器的静音状态（per-display mute）
    func setDisplayMuted(_ muted: Bool, forDisplayID displayID: UInt32) {
        guard isAvailable else { return }
        guard let container = sharedContainerURL else { return }

        let prefsURL = container.appendingPathComponent(prefsFileName)
        var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
        if muted {
            if prefs.mutedDisplayIDs == nil { prefs.mutedDisplayIDs = [] }
            prefs.mutedDisplayIDs?.insert(displayID)
        } else {
            prefs.mutedDisplayIDs?.remove(displayID)
        }
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: prefsURL, options: .atomic)
        }
        notifyExtensionPrefsChanged()
    }

    // MARK: - Notification Helpers

    /// 通知 Extension 偏好设置已变更
        func notifyExtensionPrefsChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("com.waifux.app.wallpaper.prefsChanged" as CFString),
            nil, nil, true
        )
    }

    /// 清理不再需要的旧视频，保留 keepIDs 中的所有视频
    private func cleanupOldVideos(in directory: URL, keeping keepIDs: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            if !keepIDs.contains(name) {
                try? fm.removeItem(at: file)
                print("[LockScreenWallpaper] 🗑️ 清理旧视频: \(name)")
            }
        }
    }

    // MARK: - Display Instances

    /// 当前显示器对应的锁屏实例目录。
    /// 用户在系统设置里手动为每块显示器选择一次这些实例，之后实例只负责接收对应显示器的推帧。
    func currentDisplayInstances() -> [DisplayInstance] {
        NSScreen.screens.compactMap { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = screenNumber.uint32Value
            let instanceID = "display-\(displayID)"
            let thumbnailPath = posterThumbnailPath(for: screen)
            return DisplayInstance(
                id: instanceID,
                displayID: displayID,
                name: screen.localizedName,
                thumbnailPath: thumbnailPath
            )
        }
        .sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.displayID < rhs.displayID }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func syncDisplayInstancesToSocketServer() {
        guard #available(macOS 26.0, *), isAvailable else { return }

        let instances = currentDisplayInstances()
        persistDisplayInstances(instances)

        let videos = instances.map { instance in
            IPCVideoInfo(
                id: instance.id,
                name: instance.name,
                videoPath: "",
                thumbnailPath: instance.thumbnailPath ?? ""
            )
        }
        WallpaperExtensionSocketServer.shared.updateVideos(videos)
        notifyExtensionPrefsChanged()
        print("[LockScreenWallpaper] 🖥️ 已同步 \(instances.count) 个显示器实例到 Socket 服务端")
    }

    func loadDisplayInstances() -> [DisplayInstance] {
        guard let url = displayInstancesURL,
              let data = try? Data(contentsOf: url),
              let instances = try? JSONDecoder().decode([DisplayInstance].self, from: data) else {
            return currentDisplayInstances()
        }
        return instances
    }

    /// 彻底清理锁屏实例：清除视频缓存、偏好设置、显示器实例列表、推送管线。
    /// 用户不再使用锁屏动态壁纸时调用。
    func clearLockScreenInstances() {
        guard isAvailable else { return }

        // 1. 清空视频缓存和偏好，但先不要通知扩展，避免扩展在“半清理状态”下抢先刷新。
        clearMirroringSourceCache(notify: false)

        // 2. 清空 Socket 服务端所有注册状态
        WallpaperExtensionSocketServer.shared.clearLocalDecodeVideos()
        WallpaperExtensionSocketServer.shared.clearSurfaces()
        WallpaperExtensionSocketServer.shared.updateVideos([])

        // 3. 删除显示器实例列表文件
        if let url = displayInstancesURL {
            try? FileManager.default.removeItem(at: url)
        }

        // 4. 重置 VideoWallpaperManager 的扩展活跃状态
        VideoWallpaperManager.shared.clearExtensionState()

        // 5. 自动关闭设置中的动态锁屏开关
        UserDefaults.standard.set(false, forKey: "dynamic_lock_screen_enabled")

        // 6. 最后统一通知扩展刷新（此时所有状态已清理完毕）
        notifyExtensionPrefsChanged()

        print("[LockScreenWallpaper] ✅ 已彻底清理锁屏实例")
    }

    private func persistDisplayInstances(_ instances: [DisplayInstance]) {
        guard let url = displayInstancesURL,
              let data = try? JSONEncoder().encode(instances) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private func posterThumbnailPath(for screen: NSScreen) -> String? {
        let thumbDir = sharedContainerURL?.appendingPathComponent("WallpaperCache/thumbnails")
        guard let thumbDir else { return nil }

        // 1. 按显示器实例查找。文件名带版本，避免系统设置按相同 path 缓存旧预览。
        let screenPrefixes = [
            "display-\(screen.wallpaperScreenIdentifier)",
            "\(screen.wallpaperScreenIdentifier)"
        ]
        for prefix in screenPrefixes {
            if let path = latestThumbnailPath(in: thumbDir, prefix: prefix) {
                return path
            }
        }

        // 2. 按当前桌面视频的 videoID 查找（generateThumbnail 使用 videoID 命名）
        if let videoURL = VideoWallpaperManager.shared.videoURL(for: screen),
           videoURL.isFileURL {
            let videoID = videoURL.deletingPathExtension().lastPathComponent
            let videoThumbURL = thumbDir.appendingPathComponent("\(videoID).jpg")
            if FileManager.default.fileExists(atPath: videoThumbURL.path) {
                return videoThumbURL.path
            }
        }

        return nil
    }

    // MARK: - 缩略图

    /// 生成视频的 JPEG 缩略图并写入共享容器供扩展读取
    private func generateThumbnail(for videoURL: URL, videoID: String) {
        guard let container = sharedContainerURL else { return }
        let thumbDir = container.appendingPathComponent("WallpaperCache/thumbnails")
        try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        let thumbURL = thumbDir.appendingPathComponent("\(videoID).jpg")

        if FileManager.default.fileExists(atPath: thumbURL.path) { return }

        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        var actualTime: CMTime = .zero
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: &actualTime) else {
            print("[LockScreenWallpaper] ⚠️ 缩略图生成失败: \(videoURL.lastPathComponent)")
            return
        }

        guard let dest = CGImageDestinationCreateWithURL(thumbURL as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        if CGImageDestinationFinalize(dest) {
            print("[LockScreenWallpaper] ✅ 缩略图已生成: \(thumbURL.lastPathComponent)")
        }
    }

    private static func displayInstanceID(_ displayID: UInt32) -> String {
        "display-\(displayID)"
    }

    private func normalizedImageExtension(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "webp", "tiff", "bmp"].contains(ext) {
            return ext == "jpeg" ? "jpg" : ext
        }
        return "jpg"
    }

    private func cleanupCachedImages(sourceID: String, in imageDir: URL) {
        for ext in ["jpg", "jpeg", "png", "heic", "webp", "tiff", "bmp"] {
            try? FileManager.default.removeItem(at: imageDir.appendingPathComponent("\(sourceID).\(ext)"))
        }
    }

    private func thumbnailDirectory() -> URL? {
        guard let container = sharedContainerURL else { return nil }
        let thumbDir = container.appendingPathComponent("WallpaperCache/thumbnails")
        try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        return thumbDir
    }

    private func writeThumbnail(imageData: Data, thumbnailID: String) {
        guard let thumbDir = thumbnailDirectory(),
              let image = NSImage(data: imageData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let dest = CGImageDestinationCreateWithURL(
                versionedThumbnailURL(prefix: thumbnailID, in: thumbDir) as CFURL,
                "public.jpeg" as CFString,
                1,
                nil
              ) else {
            print("[LockScreenWallpaper] ⚠️ 静态图缩略图生成失败: \(thumbnailID)")
            return
        }
        cleanupCachedThumbnails(prefix: thumbnailID, in: thumbDir)
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        if CGImageDestinationFinalize(dest) {
            print("[LockScreenWallpaper] ✅ 静态图缩略图已写入: \(thumbnailID)")
        }
    }

    private func copyVideoThumbnailToDisplayThumbnails(videoID: String, displayIDs: [UInt32]) {
        guard let thumbDir = thumbnailDirectory() else { return }
        let sourceURL = thumbDir.appendingPathComponent("\(videoID).jpg")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }

        for displayID in displayIDs {
            let prefix = Self.displayInstanceID(displayID)
            cleanupCachedThumbnails(prefix: prefix, in: thumbDir)
            let destURL = versionedThumbnailURL(prefix: prefix, in: thumbDir)
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                print("[LockScreenWallpaper] ✅ 已刷新显示器实例缩略图: \(destURL.lastPathComponent)")
            } catch {
                print("[LockScreenWallpaper] ⚠️ 显示器实例缩略图复制失败: \(error.localizedDescription)")
            }
        }
    }

    private func versionedThumbnailURL(prefix: String, in thumbDir: URL) -> URL {
        let milliseconds = Int(Date().timeIntervalSince1970 * 1000)
        let suffix = UUID().uuidString.prefix(8)
        return thumbDir.appendingPathComponent("\(prefix)-\(milliseconds)-\(suffix).jpg")
    }

    private func cleanupCachedThumbnails(prefix: String, in thumbDir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: thumbDir, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where isThumbnail(file, matching: prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func latestThumbnailPath(in thumbDir: URL, prefix: String) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: thumbDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return nil
        }
        let matches = files.filter { isThumbnail($0, matching: prefix) }
        let latest = matches.max { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if lhsDate == rhsDate {
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
            return lhsDate < rhsDate
        }
        return latest?.path
    }

    private func isThumbnail(_ url: URL, matching prefix: String) -> Bool {
        guard url.pathExtension.lowercased() == "jpg" else { return false }
        let name = url.deletingPathExtension().lastPathComponent
        return name == prefix || name.hasPrefix("\(prefix)-")
    }

    // MARK: - Socket IPC 集成

    /// 将当前显示器实例目录同步到 Socket IPC 服务端。
    func syncInstanceCatalogToSocketServer(notify: Bool = true) {
        guard #available(macOS 26.0, *) else { return }
        guard UserDefaults.standard.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else {
            print("[LockScreenWallpaper] syncInstanceCatalogToSocketServer: 动态锁屏已关闭，跳过")
            return
        }
        // 始终使用 currentDisplayInstances() 获取最新缩略图路径，而非从缓存文件读取
        let instances = currentDisplayInstances()
        persistDisplayInstances(instances)
        let instanceInfos = instances.map { instance in
            IPCVideoInfo(
                id: instance.id,
                name: instance.name,
                videoPath: "",
                thumbnailPath: instance.thumbnailPath ?? ""
            )
        }
        WallpaperExtensionSocketServer.shared.updateVideos(instanceInfos)
        if notify {
            notifyExtensionPrefsChanged()
        }
        print("[LockScreenWallpaper] 📋 已同步 \(instanceInfos.count) 个显示器实例到 Socket 服务端")
    }

    // MARK: - Types

    private struct PrefsFile: Codable {
        var userPaused: Bool = false
        var alwaysPauseDesktop: Bool = false
        var currentVideoPath: String?
        var currentImagePath: String?
        var currentRealtimeSourceKind: String?
        /// Per-display pause: displayID 集合
        var pausedDisplayIDs: Set<UInt32>?
        /// Per-display mute: displayID 集合
        var mutedDisplayIDs: Set<UInt32>?
    }
}

enum LockScreenError: LocalizedError {
    case fileNotFound
    case appGroupNotAvailable
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "视频文件不存在"
        case .appGroupNotAvailable: return "App Group 共享容器不可用"
        case .copyFailed(let msg): return "复制失败: \(msg)"
        }
    }
}
