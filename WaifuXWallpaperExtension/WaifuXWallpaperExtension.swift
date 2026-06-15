//  WaifuX Wallpaper Extension
//  基于 WallpaperExtensionKit 私有框架实现锁屏动态壁纸
//  仅在 macOS 26.0+ 生效

import AppKit
import ExtensionFoundation
import Foundation
import os

struct WallpaperExtensionConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        extLog("XPC from PID=\(connection.processIdentifier)")

        let exported = NSXPCInterface(with: WallpaperExtensionXPCProtocol.self)

        // 构建 XPC 类型白名单（从运行时加载的 WallpaperExtensionKit 类）
        let typeNames = [
            "WallpaperIDXPC",
            "WallpaperCreationRequestXPC",
            "WallpaperUpdateRequestXPC",
            "WallpaperRemoteContextXPC",
            "WallpaperSnapshotXPC",
            "WallpaperContentTypeSetXPC",
            "WallpaperChoiceIDXPC",
            "WallpaperChoiceIDsXPC",
            "WallpaperExtensionChoiceRequestXPC",
            "WallpaperChoiceRequestAdditionResultXPC",
            "WallpaperDebugRequestXPC",
            "WallpaperDebugResponseXPC",
            "WallpaperMigrationVersionXPC",
            "WallpaperSettingsViewModelsXPC",
            "AuditTokenXPC",
        ]

        let allTypes = NSMutableSet()
        var missing: [String] = []
        for name in typeNames {
            if let cls = objc_getClass(name) {
                allTypes.add(cls)
            } else {
                missing.append(name)
            }
        }
        if !missing.isEmpty {
            extLog("  MISSING types: \(missing.joined(separator: ", "))")
        }
        allTypes.add(NSString.self)
        allTypes.add(NSNumber.self)
        allTypes.add(NSData.self)
        allTypes.add(NSArray.self)
        allTypes.add(NSDictionary.self)
        allTypes.add(NSURL.self)
        allTypes.add(NSError.self)

        let classes = allTypes as! Set<AnyHashable>

        let selectors: [(Selector, Int, Bool)] = [
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.update(withId:request:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.update(withId:request:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.invalidate(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.snapshot(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.snapshot(withId:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.removeChoiceRequest(withChoiceRequest:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.selectedChoicesDidChange(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.isChoiceDownloaded(with:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.download(withChoiceID:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.pauseDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.cancelDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.resumeDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.removeDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrateSelectedChoice(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrateSelectedChoice(for:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.migrate(from:to:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrate(from:to:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.skipShuffledContent(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.canSkipShuffledContent(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.handleDebugRequest(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.handleDebugRequest(for:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.handleNotification(withNamed:reply:)), 0, false),
        ]

        for (sel, idx, isReply) in selectors {
            exported.setClasses(classes, for: sel, argumentIndex: idx, ofReply: isReply)
        }

        connection.exportedInterface = exported
        connection.remoteObjectInterface = NSXPCInterface(with: WallpaperExtensionProxyXPCProtocol.self)

        let handler = WallpaperXPCHandler()
        connection.exportedObject = handler

        connection.interruptionHandler = { extLog("XPC interrupted") }
        connection.invalidationHandler = { [weak handler] in
            handler?.agentProxy = nil
            let removed = WallpaperState.shared.removeAllContexts()
            if !removed.isEmpty {
                WallpaperPrefs.shared.setActive(false)
                extLog("XPC invalidated — cleaned up \(removed.count) active context(s)")
            } else {
                extLog("XPC invalidated")
            }
        }

        connection.resume()

        handler.agentProxy = connection.remoteObjectProxy as? WallpaperExtensionProxyXPCProtocol

        // 注册 pref 变化监听：当 App 部署新视频时通知系统刷新壁纸设置
        handler.startObservingPrefs()

        extLog("XPC accepted with full protocol")
        return true
    }
}

@main
final class WaifuXWallpaperExtension: NSObject, AppExtension {
    typealias Configuration = WallpaperExtensionConfiguration

    var configuration: WallpaperExtensionConfiguration {
        WallpaperExtensionConfiguration()
    }

    override required init() {
        super.init()

        guard #available(macOS 26.0, *) else {
            extLog("INIT — macOS < 26, WallpaperExtensionKit disabled")
            return
        }

        let frameworkPath = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        if let handle = dlopen(frameworkPath, RTLD_LAZY) {
            _ = handle
            extLog("INIT (PID: \(ProcessInfo.processInfo.processIdentifier)) — WallpaperExtensionKit loaded")
            swizzleSnapshotEncodeIfNeeded()
            VideoLibrary.shared.scan()
            WallpaperPrefs.shared.observeChanges()
            observeLibraryChanges()
            observeAppTermination()
            observeDisplaySleepWake()
            observeScreenLockState()
            PowerMonitor.shared.startMonitoring()
            observePowerStateChanges()
            observeSocketCommands()
            observeSocketCommandNotifications()
            observeExtensionReload()
        } else {
            let err = String(cString: dlerror())
            extLog("INIT — dlopen failed: \(err)")
        }
    }

    private func observeAppTermination() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                extLog("[Extension] App will terminate — releasing frame pipeline")
                FrameChannel.shared.stop()
                let removed = WallpaperState.shared.removeAllContexts()
                WallpaperPrefs.shared.setActive(false)
                extLog("[Extension] Released \(removed.count) active context(s), exiting extension process")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    exit(0)
                }
            },
            "com.waifux.app.wallpaper.appWillTerminate" as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// 监听 App 重启时的扩展重载通知。
    /// App 更新后启动时发送此通知，旧扩展进程退出，macOS WallpaperAgent 从新 bundle 重新加载。
    /// App 正常退出不触发此通知，扩展继续运行以保持锁屏壁纸不中断。
    private func observeExtensionReload() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                extLog("[Extension] Reload requested by app — exiting to allow new version to load")
                FrameChannel.shared.stop()
                let removed = WallpaperState.shared.removeAllContexts()
                WallpaperPrefs.shared.setActive(false)
                extLog("[Extension] Released \(removed.count) active context(s), exiting")
                exit(0)
            },
            "com.waifux.app.wallpaper.extensionReload" as CFString,
            nil,
            .deliverImmediately
        )
        extLog("[Extension] Reload notification observer registered")
    }

    // MARK: - SnapshotXPC Swizzle

    private func swizzleSnapshotEncodeIfNeeded() {
        guard let snapshotClass = NSClassFromString("WallpaperSnapshotXPC") else { return }
        let sel = NSSelectorFromString("encodeWithCoder:")
        guard let origMethod = class_getInstanceMethod(snapshotClass, sel) else { return }
        let origIMP = method_getImplementation(origMethod)
        typealias EncodeFunc = @convention(c) (AnyObject, Selector, NSCoder) -> Void
        let origFunc = unsafeBitCast(origIMP, to: EncodeFunc.self)
        guard let nsxpcCoderClass = NSClassFromString("NSXPCCoder") else { return }

        let block: @convention(block) (AnyObject, NSCoder) -> Void = { obj, coder in
            let origClass: AnyClass = object_getClass(coder)!
            object_setClass(coder, nsxpcCoderClass)
            origFunc(obj, sel, coder)
            object_setClass(coder, origClass)
        }
        let newIMP = imp_implementationWithBlock(block)
        method_setImplementation(origMethod, newIMP)
        extLog("  [Swizzle] Patched WallpaperSnapshotXPC encodeWithCoder:")
    }

    // MARK: - Display Sleep/Wake

    private func observeDisplaySleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { _ in
            WallpaperState.shared.isDisplayAsleep = true
            WallpaperState.shared.forEachRenderer { $0.applyPolicy(.paused) }
            extLog("[Extension] Displays asleep — paused all renderers")
        }
        center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { _ in
            WallpaperState.shared.isDisplayAsleep = false
            Self.recomputeAndApplyPolicy()
            extLog("[Extension] Displays awake — recomputed policy")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Self.recomputeAndApplyPolicy()
            }
        }
    }

    // MARK: - Screen Lock

    private func observeScreenLockState() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { _ in
            WallpaperState.shared.isScreenLocked = true
            extLog("[Extension] Screen locked")
        }
        dnc.addObserver(
            forName: .init("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { _ in
            WallpaperState.shared.isScreenLocked = false
            Self.recomputeAndApplyPolicy()
            extLog("[Extension] Screen unlocked — recomputed policy")
        }
    }

    // MARK: - Power State Changes

    /// 监听电源状态变化（热状态、电池、亮度）并重新计算播放策略
    private func observePowerStateChanges() {
        Task {
            for await powerState in PowerMonitor.shared.stateChanges() {
                let state = WallpaperState.shared
                let prefs = WallpaperPrefs.shared
                let policy = PlaybackPolicy.compute(
                    presentationMode: state.presentationMode,
                    activityState: state.activityState,
                    userPaused: prefs.userPaused,
                    alwaysPauseDesktop: prefs.alwaysPauseDesktop,
                    pauseWhenOccluded: false,
                    desktopOccluded: false,
                    powerState: powerState
                )
                WallpaperState.shared.forEachRenderer { renderer in
                    renderer.applyPolicy(policy)
                }
            }
        }
    }

    // MARK: - Socket Command Polling

    /// 定期轮询 App 的挂起命令（如 switch_video），实现 App 主动推送切换壁纸。
    /// 用户只需在系统设置初始化选择一次，之后 App 通过 socket 控制。
    private func observeSocketCommands() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Self.drainPendingSocketCommands(reason: "timer")
        }
        extLog("[Extension] Socket command polling started")
    }

    private func observeSocketCommandNotifications() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    WaifuXWallpaperExtension.drainPendingSocketCommands(reason: "commandsChanged")
                }
            },
            "com.waifux.app.wallpaper.commandsChanged" as CFString,
            nil,
            .deliverImmediately
        )
        extLog("[Extension] Socket command notification observer started")
    }

    static func drainPendingSocketCommands(reason: String) {
        var handledCount = 0
        for _ in 0..<16 {
            guard pollAndHandleSocketCommand() else { break }
            handledCount += 1
        }
        if handledCount > 0 {
            extLog("[Commands] Drained \(handledCount) pending command(s), reason=\(reason)")
        }
    }

    @discardableResult
    private static func pollAndHandleSocketCommand() -> Bool {
        guard let socketPath = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app")?
            .appendingPathComponent("socket/extension.ipc").path
        else { return false }

        let req = IPCRequest(id: UUID().uuidString, method: "poll_commands", params: nil)
        guard let data = try? JSONEncoder().encode(req) else { return false }

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var noSigPipe: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            Darwin.strncpy(&addr.sun_path.0, src, MemoryLayout.size(ofValue: addr.sun_path))
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafeMutablePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, len) } }) == 0 else { return false }

        var reqLen = UInt32(data.count).bigEndian
        guard write(sock, &reqLen, 4) == 4 else { return false }
        guard data.withUnsafeBytes({ write(sock, $0.baseAddress!, data.count) }) == data.count else { return false }

        var respLen: UInt32 = 0
        guard read(sock, &respLen, 4) == 4 else { return false }
        let payloadLen = Int(UInt32(bigEndian: respLen))
        guard payloadLen > 0, payloadLen < 10_000 else { return false }

        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: payloadLen, alignment: 1)
        defer { buf.deallocate() }
        var total = 0
        while total < payloadLen {
            let n = read(sock, buf.baseAddress! + total, payloadLen - total)
            guard n > 0 else { return false }
            total += n
        }

        let respData = Data(bytes: buf.baseAddress!, count: payloadLen)
        guard let resp = try? JSONDecoder().decode(IPCResponse.self, from: respData),
              let cmdJSON = resp.videoPath,
              let cmdData = cmdJSON.data(using: .utf8),
              let cmd = try? JSONDecoder().decode(IPCCommand.self, from: cmdData) else {
            return false
        }

        handleSocketCommand(cmd)
        return true
    }

    private static func handleSocketCommand(_ cmd: IPCCommand) {
        if cmd.action == "switch_video", let videoID = cmd.videoID, let displayID = cmd.displayID {
            extLog("[Commands] Socket switch_video: display=\(displayID) video=\(videoID)")
            if let path = UnixSocketClient.shared.fetchVideoPathSync(for: videoID) {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path) {
                    WallpaperState.shared.cachedVideoURL = url
                    WallpaperState.shared.cachedImageURL = nil
                    WallpaperState.shared.removeIOSurfaceRenderer(for: displayID)
                    FrameChannel.shared.unregisterCallback(displayID: displayID)
                    if let active = WallpaperState.shared.activeContextForCommand(displayID: displayID),
                       let renderer = active.renderer {
                        renderer.replaceVideo(with: url)
                        _ = WallpaperState.shared.replaceContextRendererForCommand(displayID: displayID, renderer: renderer, videoID: videoID)
                        WallpaperPrefs.shared.updateCurrentVideo()
                        WallpaperXPCHandler.writeSnapshotCacheIfPossible(videoURL: url, videoID: videoID, rootLayer: active.rootLayer)
                        extLog("[Commands] ✅ 已热切换显示器 \(displayID) 到视频: \(videoID)")
                    } else if let active = WallpaperState.shared.activeContextForCommand(displayID: displayID) {
                        // handleSocketCommand 始终在主线程调用，rootLayer 在此之后
                        // 不会被其他线程修改，使用 nonisolated(unsafe) 绕过严格的 Sendable 检查。
                        let rootLayer = active.rootLayer
                        // ⚠️ 必须 @MainActor：AVSampleBufferDisplayLayer 的创建和添加到 rootLayer
                        // 需要在主线程执行，否则视频不会动画（displayLayer 无帧输出）。
                        Task { @MainActor in
                            do {
                                WallpaperState.shared.removeIOSurfaceRenderer(for: displayID)
                                FrameChannel.shared.unregisterCallback(displayID: displayID)
                                rootLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
                                let renderer = try await VideoRenderer.create(rootLayer: rootLayer, videoURL: url)
                                let oldRenderer = WallpaperState.shared.replaceContextRendererForCommand(displayID: displayID, renderer: renderer, videoID: videoID)
                                oldRenderer?.stop()
                                renderer.start()
                                WallpaperPrefs.shared.updateCurrentVideo()
                                WallpaperXPCHandler.writeSnapshotCacheIfPossible(videoURL: url, videoID: videoID, rootLayer: rootLayer)
                                extLog("[Commands] ✅ 已从静态图切回视频: display=\(displayID) video=\(videoID)")
                            } catch {
                                extLog("[Commands] ❌ 从静态图切回视频失败: \(error.localizedDescription)")
                            }
                        }
                    } else {
                        // 无活跃上下文（扩展刚重启），缓存视频等待 acquire 后自动应用
                        WallpaperState.shared.setPendingVideo(url, for: displayID)
                        extLog("[Commands] ⏳ 无活跃上下文 display=\(displayID)，已缓存待处理视频: \(videoID)")
                    }
                }
            }
        } else if cmd.action == "switch_image", let sourceID = cmd.videoID, let displayID = cmd.displayID {
            extLog("[Commands] Socket switch_image: display=\(displayID) source=\(sourceID)")
            if let path = UnixSocketClient.shared.fetchVideoPathSync(for: sourceID) {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path) {
                    WallpaperState.shared.cachedImageURL = url
                    WallpaperState.shared.cachedVideoURL = nil
                    WallpaperXPCHandler.switchActiveContextToStaticImage(displayID: displayID, sourceID: sourceID, imageURL: url)
                }
            }
        }
    }

    // MARK: - Library Changes

    private func observeLibraryChanges() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                VideoLibrary.shared.scan()
                WallpaperState.shared.clearCaches()
                extLog("[Extension] Library changed — re-scanned")
                DispatchQueue.main.async {
                    WaifuXWallpaperExtension.drainPendingSocketCommands(reason: "prefsChanged")
                }
            },
            "com.waifux.app.wallpaper.prefsChanged" as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// 重新计算播放策略并应用到所有渲染器。
    /// 处理锁屏时的竞争条件：当屏幕已锁定但 WallpaperAgent 尚未更新 presentationMode 时，
    /// 使用 "locked" 防止陈旧的桌面模式策略阻止锁屏播放。
    static func recomputeAndApplyPolicy() {
        let state = WallpaperState.shared
        let prefs = WallpaperPrefs.shared
        let power = PowerMonitor.shared.currentState

        let effectiveMode = state.isScreenLocked && state.presentationMode != "locked"
            ? "locked"
            : state.presentationMode

        let policy = PlaybackPolicy.compute(
            presentationMode: effectiveMode,
            activityState: state.activityState,
            userPaused: prefs.userPaused,
            alwaysPauseDesktop: prefs.alwaysPauseDesktop,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            powerState: power
        )
        WallpaperState.shared.forEachRenderer { renderer in
            renderer.applyPolicy(policy)
        }
    }
}

// MARK: - Logging

private var extLogFileURL: URL {
    if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") {
        return container.appendingPathComponent("waifux-extension.log")
    }
    return URL(fileURLWithPath: "/tmp/waifux-extension.log")
}

func extLog(_ message: String) {
    if #available(macOS 11.0, *) {
        os_log("[WaifuXExt] %{public}@", log: .default, type: .info, message)
    } else {
        print("[WaifuXExt] \(message)")
    }
    // 也写入文件便于调试
    let line = "[\(Date())] \(message)\n"
    if let handle = try? FileHandle(forWritingTo: extLogFileURL) {
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
        try? handle.close()
    } else {
        try? line.write(to: extLogFileURL, atomically: true, encoding: .utf8)
    }
}
