//  XPC handler implementing WallpaperExtensionXPCProtocol

import AppKit
import AVFoundation
import CoreMedia
import ImageIO
import os
import QuartzCore

extension CALayer: @unchecked @retroactive Sendable {}
extension CAContext: @unchecked @retroactive Sendable {}

final class WallpaperXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    var agentProxy: (any WallpaperExtensionProxyXPCProtocol)?
    private var previousPresentationMode = "default"

    private static func extractWallpaperContextIdentifier(from object: Any?) -> String? {
        guard let object else { return nil }

        func normalizedIdentifier(from raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "nil" else { return nil }

            if let range = trimmed.range(
                of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
                options: .regularExpression
            ) {
                return "uuid:\(trimmed[range].lowercased())"
            }

            if !trimmed.contains("0x") {
                return "raw:\(trimmed)"
            }

            return nil
        }

        if let string = object as? String, let normalized = normalizedIdentifier(from: string) {
            return normalized
        }
        if let string = object as? NSString, let normalized = normalizedIdentifier(from: string as String) {
            return normalized
        }
        if let uuid = object as? UUID {
            return "uuid:\(uuid.uuidString.lowercased())"
        }

        let mirror = Mirror(reflecting: object)
        for child in mirror.children {
            if let string = child.value as? String, let normalized = normalizedIdentifier(from: string) {
                return normalized
            }
            if let string = child.value as? NSString, let normalized = normalizedIdentifier(from: string as String) {
                return normalized
            }
            if let uuid = child.value as? UUID {
                return "uuid:\(uuid.uuidString.lowercased())"
            }

            let childDescription = String(describing: child.value)
            if let normalized = normalizedIdentifier(from: childDescription) {
                return normalized
            }
        }

        return normalizedIdentifier(from: String(describing: object))
    }

    private static func displayMetrics(for displayID: UInt32) -> (size: CGSize, scale: CGFloat)? {
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  screenNumber.uint32Value == displayID else {
                continue
            }
            return (screen.frame.size, screen.backingScaleFactor)
        }

        let cgDisplayID = CGDirectDisplayID(displayID)
        let bounds = CGDisplayBounds(cgDisplayID)
        guard bounds.width > 0, bounds.height > 0 else {
            let pixelWidth = CGDisplayPixelsWide(cgDisplayID)
            let pixelHeight = CGDisplayPixelsHigh(cgDisplayID)
            guard pixelWidth > 0, pixelHeight > 0 else { return nil }
            return (CGSize(width: pixelWidth, height: pixelHeight), 1.0)
        }
        return (bounds.size, 1.0)
    }

    private static func requestDisplayGeometry(from request: Any?) -> (displayID: UInt32?, size: CGSize?, scale: CGFloat?) {
        var descriptions: [String] = []

        func collectDescriptions(_ value: Any, depth: Int) {
            guard depth < 3, descriptions.count < 24 else { return }
            descriptions.append(String(describing: value))
            for child in Mirror(reflecting: value).children {
                collectDescriptions(child.value, depth: depth + 1)
            }
        }

        if let request {
            collectDescriptions(request, depth: 0)
        }

        func number(after marker: String) -> Double? {
            for desc in descriptions {
                guard let range = desc.range(of: marker) else { continue }
                let tail = desc[range.upperBound...].drop(while: { $0 == " " })
                let token = tail.prefix { char in
                    char.isNumber || char == "." || char == "-"
                }
                if let value = Double(token) {
                    return value
                }
            }
            return nil
        }

        let displayID = number(after: "directDisplayID: ").flatMap { UInt32(exactly: Int($0)) }
            ?? number(after: "displayID: ").flatMap { UInt32(exactly: Int($0)) }
        let width = number(after: "width: ")
        let height = number(after: "height: ")
        let size: CGSize?
        if let width, let height, width > 0, height > 0 {
            size = CGSize(width: width, height: height)
        } else {
            size = nil
        }
        let scale = number(after: "scaleFactor: ").flatMap { $0 > 0 ? CGFloat($0) : nil }
        return (displayID, size, scale)
    }

    private static func applyDisplayGeometryUpdate(
        wallpaperID: String?,
        displayID: UInt32?,
        size requestedSize: CGSize?,
        scale requestedScale: CGFloat?
    ) {
        let contexts: [ActiveWallpaper]
        if let wallpaperID,
           let active = WallpaperState.shared.activeContext(wallpaperID: wallpaperID) {
            contexts = [active]
        } else if let displayID,
                  let active = WallpaperState.shared.activeContextForCommand(displayID: displayID) {
            contexts = [active]
        } else if displayID != nil {
            contexts = []
        } else {
            contexts = WallpaperState.shared.activeContextsSnapshot()
        }

        guard !contexts.isEmpty else { return }

        let applyBlock: @Sendable () -> Void = {
            for active in contexts {
                let targetDisplayID = displayID ?? active.displayID
                guard let targetDisplayID else { continue }

                let metrics = Self.displayMetrics(for: targetDisplayID)
                let targetSize = requestedSize ?? metrics?.size
                let targetScale = requestedScale ?? metrics?.scale ?? active.rootLayer.contentsScale
                guard let targetSize, targetSize.width > 0, targetSize.height > 0 else { continue }

                let oldBounds = active.rootLayer.bounds
                let oldScale = active.rootLayer.contentsScale
                let needsFrame = abs(oldBounds.width - targetSize.width) > 0.5
                    || abs(oldBounds.height - targetSize.height) > 0.5
                let needsScale = abs(oldScale - targetScale) > 0.001
                guard needsFrame || needsScale else { continue }

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                active.rootLayer.frame = CGRect(origin: .zero, size: targetSize)
                active.rootLayer.bounds = CGRect(origin: .zero, size: targetSize)
                active.rootLayer.contentsScale = targetScale
                active.renderer?.relayoutForCurrentDisplayGeometry()

                // IOSurface 渲染器也需要重新布局
                if let ioRenderer = WallpaperState.shared.ioSurfaceRenderer(for: targetDisplayID) {
                    ioRenderer.relayout(rootLayer: active.rootLayer)

                    // 分辨率变化时重新分配 surface 并通知 App
                    let pixelWidth = Int(targetSize.width * targetScale)
                    let pixelHeight = Int(targetSize.height * targetScale)
                    if #available(macOS 15.0, *) {
                        if let newIDs = ioRenderer.reallocateSurfacesIfNeeded(width: pixelWidth, height: pixelHeight) {
                            Task {
                                _ = await UnixSocketClient.shared.registerSurfaces(
                                    displayID: targetDisplayID,
                                    surfaceID0: newIDs.surfaceID0,
                                    surfaceID1: newIDs.surfaceID1,
                                    videoID: active.videoID ?? ""
                                )
                                extLog("[Geometry] re-registered surfaces display=\(targetDisplayID) [\(newIDs.surfaceID0), \(newIDs.surfaceID1)]")
                            }
                        }
                    }
                }

                CATransaction.commit()

                if let wallpaperID, active.displayID != targetDisplayID {
                    WallpaperState.shared.updateContextDisplayID(wallpaperID: wallpaperID, displayID: targetDisplayID)
                } else if active.displayID != targetDisplayID {
                    WallpaperState.shared.updateContextDisplayID(rootLayer: active.rootLayer, displayID: targetDisplayID)
                }

                extLog(
                    "[Geometry] updated display=\(targetDisplayID) "
                        + "\(Int(oldBounds.width))x\(Int(oldBounds.height))@\(oldScale) -> "
                        + "\(Int(targetSize.width))x\(Int(targetSize.height))@\(targetScale)"
                )
            }
        }

        if Thread.isMainThread {
            applyBlock()
        } else {
            DispatchQueue.main.async(execute: applyBlock)
        }
    }

    // MARK: - Lifecycle

    func acquire(withId id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extLog("=== ACQUIRE ===")

        let wallpaperIDString = Self.extractWallpaperContextIdentifier(from: id)

        // Extract displayID and destSize from request via Mirror
        var displayID: UInt32?
        var destSize = CGSize(width: 1920, height: 1080)
        var didParseDestinationSize = false
        var scaleFactor: CGFloat = 1.0
        var choiceConfiguration: String?

        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            if let innerValue = mirror.children.first?.value {
                let desc = String(describing: innerValue)
                if let dRange = desc.range(of: "displayID: ") {
                    let after = desc[dRange.upperBound...]
                    if let end = after.range(of: ",") ?? after.range(of: ")") {
                        displayID = UInt32(after[..<end.lowerBound].trimmingCharacters(in: .whitespaces))
                    }
                }
                if let wRange = desc.range(of: "width: "), let hRange = desc.range(of: "height: ") {
                    let afterW = desc[wRange.upperBound...]
                    let afterH = desc[hRange.upperBound...]
                    if let endW = afterW.range(of: ",") ?? afterW.range(of: ")"),
                       let endH = afterH.range(of: ",") ?? afterH.range(of: ")") {
                        destSize.width = CGFloat(Double(afterW[..<endW.lowerBound].trimmingCharacters(in: .whitespaces)) ?? 1920)
                        destSize.height = CGFloat(Double(afterH[..<endH.lowerBound].trimmingCharacters(in: .whitespaces)) ?? 1080)
                        didParseDestinationSize = destSize.width > 0 && destSize.height > 0
                    }
                }
                if let sRange = desc.range(of: "scaleFactor: ") {
                    let after = desc[sRange.upperBound...]
                    if let end = after.range(of: ",") ?? after.range(of: ")") {
                        scaleFactor = CGFloat(Double(after[..<end.lowerBound].trimmingCharacters(in: .whitespaces)) ?? 1.0)
                    }
                }
                _ = desc.contains("isPreview: true")
                // 尝试解析 String 格式的 configuration: Optional("display-instance-id")
                if let cRange = desc.range(of: "configuration: Optional(\""), let cEnd = desc[cRange.upperBound...].range(of: "\")") {
                    choiceConfiguration = String(desc[cRange.upperBound..<cEnd.lowerBound])
                }
                // 回退：尝试从 Data 格式的 configuration 解析（UTF-8 字节）
                if choiceConfiguration == nil {
                    if let dataRange = desc.range(of: "configuration: Optional("),
                       let bytesRange = desc[dataRange.upperBound...].range(of: "bytes = \""),
                       let endQuote = desc[bytesRange.upperBound...].range(of: "\")") {
                        let hexStr = String(desc[bytesRange.upperBound..<endQuote.lowerBound])
                        if let data = hexStr.data(using: .utf8), !data.isEmpty {
                            choiceConfiguration = String(data: data, encoding: .utf8)
                        }
                    }
                }
                // 从 Mirror 遍历提取 cacheDirectory 和 choice files（更可靠的提取方式）
                for child in mirror.children {
                    let reqMirror = Mirror(reflecting: child.value)
                    for prop in reqMirror.children {
                        if prop.label == "destination" {
                            let destMirror = Mirror(reflecting: prop.value)
                            for destProp in destMirror.children {
                                if destProp.label == "directDisplayID", let did = destProp.value as? UInt32 {
                                    displayID = did
                                } else if destProp.label == "cacheDirectory" {
                                    if let url = prop.value as? URL {
                                        WallpaperState.shared.cacheDirectoryURL = url
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // 从 descriptor 提取配置和文件
            let rawMirror = Mirror(reflecting: reqObj)
            if let rawValue = rawMirror.children.first?.value {
                let rMirror = Mirror(reflecting: rawValue)
                for prop in rMirror.children where prop.label == "descriptor" {
                    let descMirror = Mirror(reflecting: prop.value)
                    for descProp in descMirror.children {
                        if descProp.label == "configuration" {
                            if let data = descProp.value as? Data, !data.isEmpty {
                                choiceConfiguration = String(data: data, encoding: .utf8)
                            }
                        } else if descProp.label == "files" {
                            if let urls = descProp.value as? [URL] {
                                _ = urls
                            }
                        }
                    }
                }
            }
        }

        // 回退：如果 request 没带配置，使用上一次实例 ID。
        if choiceConfiguration == nil || choiceConfiguration?.isEmpty == true {
            let fallbackID = WallpaperState.shared.currentVideoID
            if let fallbackID, !fallbackID.isEmpty {
                extLog("[acquire] ⚠️ choiceConfiguration 为 nil，回退使用 currentVideoID: \(fallbackID)")
                choiceConfiguration = fallbackID
            }
        }

        // 回退：如果 displayID 仍为 nil，尝试从 choiceConfiguration 提取
        // 实例 ID 格式为 "display-<number>"
        if displayID == nil, let config = choiceConfiguration,
           config.hasPrefix("display-"),
           let idStr = config.split(separator: "-").last,
           let parsed = UInt32(idStr) {
            displayID = parsed
            extLog("[acquire] ⚠️ 从 choiceConfiguration 提取 displayID: \(parsed) (config: \(config))")
        }

        // 最终回退：如果 displayID 为 nil，尝试从系统获取
        if displayID == nil {
            // 尝试 NSScreen（可能受限于沙箱）
            if let mainScreen = NSScreen.screens.first,
               let screenNumber = mainScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                displayID = screenNumber.uint32Value
                extLog("[acquire] ⚠️ 从 NSScreen 获取 displayID: \(displayID!)")
            }
        }
        // 最后手段：CGGetActiveDisplayList（不依赖 AppKit，沙箱安全）
        if displayID == nil {
            var count: UInt32 = 0
            if CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 {
                var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
                if CGGetActiveDisplayList(count, &displays, &count) == .success {
                    displayID = displays[0]
                    extLog("[acquire] ⚠️ 从 CGGetActiveDisplayList 获取 displayID: \(displayID!)")
                }
            }
        }
        if displayID == nil {
            extLog("[acquire] ❌ 无法确定 displayID，无法创建渲染管线")
            reply(nil, NSError(domain: "WaifuXExtension", code: 4,
                               userInfo: [NSLocalizedDescriptionKey: "Cannot determine display ID"]))
            return
        }

        if !didParseDestinationSize, let did = displayID,
           let metrics = Self.displayMetrics(for: did) {
            destSize = metrics.size
            scaleFactor = metrics.scale
            extLog("[acquire] ⚠️ request 未提供有效目标尺寸，使用 display metrics: display=\(did) size=\(Int(destSize.width))x\(Int(destSize.height)) scale=\(scaleFactor)")
        }

        // 记录当前激活的实例 ID（display instance），供状态同步和日志使用。
        if let instanceID = choiceConfiguration, !instanceID.isEmpty {
            let previousID = WallpaperState.shared.currentVideoID
            if previousID != instanceID {
                extLog("  Instance changed: \(previousID ?? "nil") → \(instanceID)")
                WallpaperState.shared.currentVideoID = instanceID
                WallpaperPrefs.shared.updateCurrentVideo()
            }
        }

        // Create remote CAContext
        var contextOptions: [String: Any] = [:]
        if let did = displayID {
            contextOptions["displayId"] = did
        }
        let caContext: CAContext
        if contextOptions.isEmpty {
            guard let ctx = CAContext.remoteContext() as? CAContext else {
                reply(nil, NSError(domain: "WaifuXExtension", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CAContext"]))
                return
            }
            caContext = ctx
        } else {
            let result = CAContext.perform(NSSelectorFromString("remoteContextWithOptions:"), with: contextOptions)?.takeUnretainedValue()
            guard let ctx = result as? CAContext else {
                reply(nil, NSError(domain: "WaifuXExtension", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CAContext"]))
                return
            }
            caContext = ctx
        }
        guard caContext.contextId != 0 else {
            reply(nil, NSError(domain: "WaifuXExtension", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CAContext"]))
            return
        }

        let contextId = caContext.contextId

        guard let replyObj = createRemoteContextXPC(contextId: contextId) else {
            reply(nil, NSError(domain: "WaifuXExtension", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create WallpaperRemoteContextXPC"]))
            return
        }

        nonisolated(unsafe) let unsafeReplyObj = replyObj
        let hasReplied = OSAllocatedUnfairLock(initialState: false)
        let doReply: @Sendable (String) -> Void = { source in
            let shouldReply = hasReplied.withLock { replied in
                if replied { return false }
                replied = true
                return true
            }
            if shouldReply {
                extLog("  Replying to acquire [\(source)] (contextId: \(contextId))")
                reply(unsafeReplyObj, nil)
            }
        }

        let layerFrame = CGRect(origin: .zero, size: destSize)
        let rootLayer = CALayer()
        rootLayer.frame = layerFrame
        rootLayer.contentsScale = scaleFactor
        rootLayer.contentsGravity = .resizeAspectFill
        extLog("[acquire] rootLayer size=\(Int(destSize.width))x\(Int(destSize.height)) scale=\(scaleFactor) display=\(displayID ?? 0)")

        if let cachedImage = loadCachedSnapshotImage() {
            rootLayer.contents = cachedImage
            extLog("  Set cached snapshot as initial layer content")
        }

        if let did = displayID {
            let instanceID = choiceConfiguration ?? "display-\(did)"
            extLog("  Setting up display instance \(instanceID) for display \(did)")
            caContext.layer = rootLayer
            CATransaction.flush()
            doReply("context ready")

            let unsafeCAContext = caContext
            let unsafeRootLayer = rootLayer

            Self.startLocalVideoFallbackTask(
                displayID: did,
                instanceID: instanceID,
                rootLayer: unsafeRootLayer,
                caContext: unsafeCAContext,
                contextId: contextId,
                wallpaperIDString: wallpaperIDString,
                doReply: doReply
            )

            DispatchQueue.global().asyncAfter(deadline: .now() + 15.0) {
                doReply("timeout")
            }
        } else {
            extLog("  No displayID in acquire request — using solid color fallback")
            let gradientLayer = CAGradientLayer()
            gradientLayer.colors = [
                CGColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1.0),
                CGColor(red: 0.0, green: 0.0, blue: 0.1, alpha: 1.0),
            ]
            gradientLayer.frame = layerFrame
            gradientLayer.contentsScale = scaleFactor
            rootLayer.addSublayer(gradientLayer)
            caContext.layer = rootLayer
            _ = WallpaperState.shared.storeContext(
                ActiveWallpaper(caContext: caContext, rootLayer: rootLayer, renderer: nil, displayID: displayID, videoID: choiceConfiguration),
                id: contextId,
                wallpaperID: wallpaperIDString
            )
            doReply("no display")
        }
    }

    private static func startLocalVideoFallbackTask(
        displayID: UInt32,
        instanceID: String,
        rootLayer: CALayer,
        caContext: CAContext,
        contextId: UInt32,
        wallpaperIDString: String?,
        doReply: @escaping @Sendable (String) -> Void
    ) {
        Task {
            extLog("  [Acquire] 使用扩展本地解码 display=\(displayID)")
            await startLocalVideoFallback(
                displayID: displayID,
                instanceID: instanceID,
                rootLayer: rootLayer,
                caContext: caContext,
                contextId: contextId,
                wallpaperIDString: wallpaperIDString,
                doReply: doReply
            )
        }
    }

    private static func startLocalVideoFallback(
        displayID: UInt32,
        instanceID: String,
        rootLayer: CALayer,
        caContext: CAContext,
        contextId: UInt32,
        wallpaperIDString: String?,
        doReply: @escaping @Sendable (String) -> Void
    ) async {
        // 优先使用待处理的视频切换（扩展重启期间 switch_video 到达但无上下文时缓存的）
        if let pendingURL = WallpaperState.shared.takePendingVideo(for: displayID) {
            extLog("  [Acquire] 📦 应用待处理视频 display=\(displayID) video=\(pendingURL.lastPathComponent)")
            do {
                let renderer = try await VideoRenderer.create(rootLayer: rootLayer, videoURL: pendingURL)
                let activeCtx = ActiveWallpaper(
                    caContext: caContext,
                    rootLayer: rootLayer,
                    renderer: renderer,
                    displayID: displayID,
                    videoID: instanceID
                )
                let existing = WallpaperState.shared.storeContext(activeCtx, id: contextId, wallpaperID: wallpaperIDString)
                existing?.renderer?.stop()
                renderer.start()
                writeSnapshotCacheIfPossible(videoURL: pendingURL, videoID: instanceID, rootLayer: rootLayer)
                WallpaperPrefs.shared.setActive(true)
                extLog("  [Acquire] ✅ 待处理视频渲染已启动 display=\(displayID) video=\(pendingURL.lastPathComponent)")
                doReply("pending video applied")
                return
            } catch {
                extLog("  [Acquire] ❌ 待处理视频渲染失败: \(error.localizedDescription)，回退到 prefs")
            }
        }

        // 先读取 App 写入的共享 prefs，确定上次设置的壁纸类型。
        // findImageURL(sourceID:) 会通过 Socket 查 localDecodeVideoLock 中残留的旧注册，
        // 导致切换壁纸后扩展冷启动仍然渲染旧内容。直接读 prefs 才能反映 App 的最后意图。
        if let videoURL = prefsVideoURL() {
            do {
                let renderer = try await VideoRenderer.create(rootLayer: rootLayer, videoURL: videoURL)
                let activeCtx = ActiveWallpaper(
                    caContext: caContext,
                    rootLayer: rootLayer,
                    renderer: renderer,
                    displayID: displayID,
                    videoID: instanceID
                )
                let existing = WallpaperState.shared.storeContext(activeCtx, id: contextId, wallpaperID: wallpaperIDString)
                existing?.renderer?.stop()
                renderer.start()
                writeSnapshotCacheIfPossible(videoURL: videoURL, videoID: instanceID, rootLayer: rootLayer)
                WallpaperPrefs.shared.setActive(true)
                extLog("  [Acquire] ✅ 本地回退渲染已启动 display=\(displayID) video=\(videoURL.lastPathComponent)")
                doReply("local video fallback")
            } catch {
                extLog("  [Acquire] ❌ 本地回退视频渲染失败: \(error.localizedDescription)")
                // 视频播放失败，尝试回退到 prefs 中指定的静态图
                if let imageURL = prefsImageURL() {
                    renderStaticImage(
                        imageURL: imageURL,
                        displayID: displayID,
                        instanceID: instanceID,
                        rootLayer: rootLayer,
                        caContext: caContext,
                        contextId: contextId,
                        wallpaperIDString: wallpaperIDString,
                        doReply: doReply
                    )
                } else {
                    WallpaperPrefs.shared.setActive(true)
                    doReply("video failed, no image fallback")
                }
            }
            return
        }

        // prefs 中 currentVideoPath 未设置 → 检查静态图
        if let imageURL = prefsImageURL() {
            renderStaticImage(
                imageURL: imageURL,
                displayID: displayID,
                instanceID: instanceID,
                rootLayer: rootLayer,
                caContext: caContext,
                contextId: contextId,
                wallpaperIDString: wallpaperIDString,
                doReply: doReply
            )
            return
        }

        // prefs 无有效设置 → 最后的回退：查 findImageURL（兼容旧状态）
        if let imageURL = findImageURL(sourceID: instanceID) {
            renderStaticImage(
                imageURL: imageURL,
                displayID: displayID,
                instanceID: instanceID,
                rootLayer: rootLayer,
                caContext: caContext,
                contextId: contextId,
                wallpaperIDString: wallpaperIDString,
                doReply: doReply
            )
            return
        }

        extLog("  [Acquire] ❌ 本地回退失败：未找到可播放视频或图片")
        WallpaperPrefs.shared.setActive(true)
        doReply("fallback no resource")
    }

    /// 从共享 prefs 读取 currentVideoPath，返回可播放的视频 URL，或 nil。
    private static func prefsVideoURL() -> URL? {
        struct MirroringPrefs: Decodable {
            let currentVideoPath: String?
        }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") else {
            return nil
        }
        let prefsURL = container.appendingPathComponent("waifux-wallpaper-prefs.json")
        guard let data = try? Data(contentsOf: prefsURL),
              let prefs = try? JSONDecoder().decode(MirroringPrefs.self, from: data),
              let path = prefs.currentVideoPath,
              !path.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            extLog("[startLocalVideoFallback] ⚠️ prefs currentVideoPath 不存在: \(path)")
            return nil
        }
        return url
    }

    /// 从共享 prefs 读取 currentImagePath，返回可显示的图片 URL，或 nil。
    private static func prefsImageURL() -> URL? {
        struct MirroringPrefs: Decodable {
            let currentImagePath: String?
        }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") else {
            return nil
        }
        let prefsURL = container.appendingPathComponent("waifux-wallpaper-prefs.json")
        guard let data = try? Data(contentsOf: prefsURL),
              let prefs = try? JSONDecoder().decode(MirroringPrefs.self, from: data),
              let path = prefs.currentImagePath,
              !path.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            extLog("[startLocalVideoFallback] ⚠️ prefs currentImagePath 不存在: \(path)")
            return nil
        }
        return url
    }

    static func writeSnapshotCacheIfPossible(videoURL: URL, videoID: String, rootLayer: CALayer) {
        let scale = rootLayer.contentsScale > 0 ? rootLayer.contentsScale : 1
        let width = max(1, Int(rootLayer.bounds.width * scale))
        let height = max(1, Int(rootLayer.bounds.height * scale))
        Task {
            await writeBMPSnapshot(
                videoURL: videoURL,
                videoID: videoID,
                displayPixelWidth: width,
                displayPixelHeight: height
            )
        }
    }

    private static func renderStaticImage(
        imageURL: URL,
        displayID: UInt32,
        instanceID: String,
        rootLayer: CALayer,
        caContext: CAContext,
        contextId: UInt32,
        wallpaperIDString: String?,
        doReply: @escaping @Sendable (String) -> Void
    ) {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            extLog("  [Acquire] ❌ 静态图加载失败: \(imageURL.path)")
            WallpaperPrefs.shared.setActive(true)
            doReply("static image failed")
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        rootLayer.contentsGravity = .resizeAspectFill
        rootLayer.contents = image
        CATransaction.commit()

        let activeCtx = ActiveWallpaper(
            caContext: caContext,
            rootLayer: rootLayer,
            renderer: nil,
            displayID: displayID,
            videoID: instanceID
        )
        let existing = WallpaperState.shared.storeContext(activeCtx, id: contextId, wallpaperID: wallpaperIDString)
        existing?.renderer?.stop()
        WallpaperPrefs.shared.setActive(true)
        extLog("  [Acquire] ✅ 静态图渲染已启动 display=\(displayID) image=\(imageURL.lastPathComponent)")
        doReply("static image")
    }

    static func switchActiveContextToStaticImage(displayID: UInt32, sourceID: String, imageURL: URL) {
        guard let active = WallpaperState.shared.activeContextForCommand(displayID: displayID),
              let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            extLog("[Commands] ❌ 静态图热切换失败 display=\(displayID) source=\(sourceID)")
            return
        }

        let rootLayer = active.rootLayer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        rootLayer.contentsGravity = .resizeAspectFill
        rootLayer.contents = image
        CATransaction.commit()

        let oldRenderer = WallpaperState.shared.replaceContextRendererForCommand(displayID: displayID, renderer: nil, videoID: sourceID)
        oldRenderer?.stop()
        WallpaperState.shared.removeIOSurfaceRenderer(for: displayID)
        FrameChannel.shared.unregisterCallback(displayID: displayID)
        WallpaperPrefs.shared.updateCurrentVideo()
        extLog("[Commands] ✅ 已热切换显示器 \(displayID) 到静态图: \(sourceID)")
    }

    func update(withId id: Any?, request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        let wallpaperIDString = Self.extractWallpaperContextIdentifier(from: id)
        let geometry = Self.requestDisplayGeometry(from: request)
        Self.applyDisplayGeometryUpdate(
            wallpaperID: wallpaperIDString,
            displayID: geometry.displayID,
            size: geometry.size,
            scale: geometry.scale
        )

        var presentationMode = "?"
        var activityState = "?"
        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            if let innerValue = mirror.children.first?.value {
                let desc = String(describing: innerValue)
                if let modeRange = desc.range(of: "presentationMode: ") {
                    let afterMode = desc[modeRange.upperBound...]
                    if let endRange = afterMode.range(of: ",") ?? afterMode.range(of: ")") {
                        presentationMode = String(afterMode[..<endRange.lowerBound])
                    }
                }
                if let actRange = desc.range(of: "activityState: ") {
                    let afterAct = desc[actRange.upperBound...]
                    if let endRange = afterAct.range(of: ",") ?? afterAct.range(of: ")") {
                        activityState = String(afterAct[..<endRange.lowerBound])
                    }
                }
            }
        }

        WallpaperState.shared.presentationMode = presentationMode
        WallpaperState.shared.activityState = activityState

        if presentationMode == "locked" {
            WallpaperState.shared.isScreenLocked = true
        } else if presentationMode != "?" {
            WallpaperState.shared.isScreenLocked = false
        }

        let prefs = WallpaperPrefs.shared
        let power = PowerMonitor.shared.currentState
        let basePolicy = PlaybackPolicy.compute(
            presentationMode: presentationMode,
            activityState: activityState,
            userPaused: prefs.userPaused,
            alwaysPauseDesktop: prefs.alwaysPauseDesktop,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            powerState: power
        )

        let modeChanged = presentationMode != previousPresentationMode
        let animated = prefs.alwaysPauseDesktop && activityState == "active" && modeChanged

        // Per-display policy：检查每个显示器是否有独立的暂停设置
        WallpaperState.shared.forEachActiveContext { displayID, renderer in
            let isDisplayPaused = displayID.flatMap { prefs.isDisplayPaused($0) } ?? false
            let effectivePolicy: PlaybackPolicy = isDisplayPaused ? .paused : basePolicy
            renderer.applyPolicy(effectivePolicy, animated: animated)
        }

        previousPresentationMode = presentationMode
        extLog("=== UPDATE === mode: \(presentationMode), activity: \(activityState)")
        reply(nil)
    }

    func invalidate(withId id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        var cleaned = false
        let identifier = Self.extractWallpaperContextIdentifier(from: id)
        if let identifier,
           let active = WallpaperState.shared.removeContext(wallpaperID: identifier) {
            active.renderer?.stop()
            cleaned = true
        }
        let remaining = WallpaperState.shared.activeContextCount
        if remaining == 0 {
            WallpaperPrefs.shared.setActive(false)
        }
        extLog("=== INVALIDATE === (identifier: \(identifier ?? "nil"), cleaned: \(cleaned), remaining: \(remaining))")
        reply(nil)
    }

    func snapshot(withId _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extLog("=== SNAPSHOT ===")
        var currentTime: CMTime?
        WallpaperState.shared.forEachRenderer { renderer in
            currentTime = CMTimebaseGetTime(renderer.timebase)
        }
        Task {
            if let snapshotXPC = await createSnapshotViaRuntime(currentTime: currentTime) {
                // 验证 XPC 编码可行性：尝试 NSKeyedArchiver 测试编码
                let canEncode: Bool
                if #available(macOS 26.0, *) {
                    canEncode = (try? NSKeyedArchiver.archivedData(withRootObject: snapshotXPC, requiringSecureCoding: false)) != nil
                } else {
                    canEncode = true
                }
                if canEncode {
                    reply(snapshotXPC, nil)
                    extLog("  Snapshot replied (IOSurface)")
                } else {
                    // XPC 编码会失败（WallpaperSnapshotXPC 缺少 encodeWithCoder:），
                    // 返回 nil 防止 XPC 异常阻断壁纸系统
                    extLog("  ⚠️ Snapshot XPC encode would fail, replying nil to avoid XPC exception")
                    reply(nil, nil)
                }
            } else {
                reply(nil, nil)
                extLog("  Snapshot replied nil")
            }
        }
    }

    // MARK: - Prefs Change Monitoring

    /// 开始监听 App 部署新视频的 Darwin 通知，并通知系统刷新壁纸设置。
    /// 在 agentProxy 设置后调用。
    func startObservingPrefs() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let handler = Unmanaged<WallpaperXPCHandler>.fromOpaque(observer).takeUnretainedValue()
                handler.handlePrefsChanged()
            },
            "com.waifux.app.wallpaper.prefsChanged" as CFString,
            nil,
            .deliverImmediately
        )
        extLog("[XPCHandler] 已注册 prefs 变化监听")
    }

    /// prefs 变化时：通知系统刷新壁纸设置，促使系统选中最新部署的视频
    private func handlePrefsChanged() {
        extLog("[XPCHandler] prefs 已变化，通知系统刷新壁纸设置...")

        // 先清除缓存，确保证 SettingsProvider 扫描到最新文件
        WallpaperState.shared.clearCaches()
        DispatchQueue.main.async {
            WaifuXWallpaperExtension.drainPendingSocketCommands(reason: "xpcPrefsChanged")
        }

        guard let proxy = agentProxy else {
            extLog("[XPCHandler] ⚠️ agentProxy 不可用，跳过刷新")
            return
        }

        nonisolated(unsafe) let unsafeProxy = proxy

        Task {
            // 构建最新的 SettingsViewModels（包含刚部署的视频）
            guard let viewModels = await buildSettingsViewModelsXPC() else {
                extLog("[XPCHandler] ⚠️ buildSettingsViewModelsXPC 返回 nil")
                return
            }

            // 通知系统刷新壁纸设置。系统收到后会重新调用 provideSettingsViewModels，
            // 从而看到最新部署的视频。
            do {
                try await unsafeProxy.updateSettingsViewModels(viewModels)
                extLog("[XPCHandler] ✅ 已通知系统刷新壁纸设置")
            } catch {
                extLog("[XPCHandler] ❌ updateSettingsViewModels 失败: \(error)")
            }
        }
    }

    // MARK: - Stubs

    func provideSettingsViewModels(withContentTypes _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        Task {
            let result = await buildSettingsViewModelsXPC()
            reply(result ?? makeEmptyGroupsResponse(), nil)
        }
    }

    func addChoiceRequest(withChoiceRequest request: Any?, onBehalfOfProcess _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extLog("=== ADD CHOICE REQUEST ===")
        reply(nil, nil)
    }

    func removeChoiceRequest(withChoiceRequest request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extLog("=== REMOVE CHOICE REQUEST ===")

        // 显示器实例不支持从扩展侧移除；这里只做日志并返回成功。
        var instanceID: String?
        if let reqObj = request as? NSObject {
            let desc = String(describing: reqObj)
            if let range = desc.range(of: "identifier: \"") {
                let after = desc[range.upperBound...]
                if let endQuote = after.firstIndex(of: "\"") {
                    instanceID = String(after[..<endQuote])
                }
            }
        }

        extLog("  [Remove] 忽略实例删除请求: \(instanceID ?? "unknown")")
        reply(nil)
    }

    func selectedChoicesDidChange(for id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extLog("=== SELECTED CHOICES DID CHANGE ===")

        // 从 WallpaperChoiceID 中提取 choice identifier
        var choiceIdentifier: String?
        if let idObj = id as? NSObject {
            let mirror = Mirror(reflecting: idObj)
            for child in mirror.children {
                let desc = String(describing: child.value)
                if let range = desc.range(of: "identifier: \"") {
                    let after = desc[range.upperBound...]
                    if let endQuote = after.firstIndex(of: "\"") {
                        choiceIdentifier = String(after[..<endQuote])
                    }
                }
            }
        }

        guard let instanceID = choiceIdentifier else {
            extLog("selectedChoicesDidChange: 未知 choice \(String(describing: choiceIdentifier))")
            reply(nil)
            return
        }

        extLog("=== INSTANCE CHANGED === id: \(instanceID)")

        WallpaperState.shared.currentVideoID = instanceID
        WallpaperPrefs.shared.updateCurrentVideo()
        reply(nil)
    }

    func invokeContextMenuAction(withMenuItemID menuItemID: Any?, groupItemID _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        let identifier = (menuItemID as? String) ?? String(describing: menuItemID ?? "nil")
        extLog("=== CONTEXT MENU ACTION === identifier: \(identifier)")
        reply(nil)
    }

    func isChoiceDownloaded(with _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        extLog("isChoiceDownloaded")
        reply(true, nil)
    }

    func download(withChoiceID _: Any?, reply: ((any Error)?) -> Void) -> Any? {
        extLog("download")
        reply(nil)
        return nil
    }

    func pauseDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func cancelDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func resumeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func removeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func migrateSelectedChoice(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extLog("migrateSelectedChoice")
        reply(nil, nil)
    }

    func migrate(from _: Any?, to _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extLog("migrate")
        reply(nil)
    }

    func skipShuffledContent(withId _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extLog("skipShuffledContent")
        reply(nil)
    }

    func canSkipShuffledContent(withId _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        extLog("canSkipShuffledContent")
        reply(false, nil)
    }

    func handleDebugRequest(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extLog("handleDebugRequest")
        reply(nil, nil)
    }

    func handleNotification(withNamed _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }
    private func createRemoteContextXPC(contextId: UInt32) -> AnyObject? {
        guard let realClass = objc_getClass("WallpaperRemoteContextXPC") as? AnyClass,
              let raw = class_createInstance(realClass, 0) else {
            extLog("  ERROR: Could not create WallpaperRemoteContextXPC")
            return nil
        }

        let obj = raw as AnyObject
        let ptr = Unmanaged.passUnretained(obj).toOpaque()
        let ivarOffset: Int = if let ivar = class_getInstanceVariable(realClass, "box") {
            ivar_getOffset(ivar)
        } else {
            8
        }
        ptr.advanced(by: ivarOffset).storeBytes(of: contextId, as: UInt32.self)
        extLog("  Created WallpaperRemoteContextXPC (contextId: \(contextId), offset: \(ivarOffset))")
        return obj
    }
}
