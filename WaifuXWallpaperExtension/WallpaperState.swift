//  线程安全的扩展共享状态
//
//  所有访问通过 OSAllocatedUnfairLock 保护，避免并发 XPC 回调竞争。
//
//  参考 Phosphene (MIT) 的实现，增加了库变化监听、display contexts、
//  cachedThumbnailURL 等特性。

import Foundation
import os
import QuartzCore

struct ActiveWallpaper: @unchecked Sendable {
    let caContext: AnyObject
    let rootLayer: CALayer
    let renderer: VideoRenderer?
    let displayID: UInt32?
    let videoID: String?
}

final class WallpaperState: Sendable {
    static let shared = WallpaperState()

    private static let selectedVideoKey = "waifux_selected_video_id"

    private struct State: @unchecked Sendable {
        var activeContexts: [UInt32: ActiveWallpaper] = [:]
        var wallpaperIDToContext: [String: UInt32] = [:]
        var cachedThumbnailURL: URL?
        var cacheDirectoryURL: URL?
        var cachedVideoURL: URL?
        var cachedImageURL: URL?
        var currentVideoID: String? = UserDefaults.standard.string(forKey: WallpaperState.selectedVideoKey)
        var presentationMode: String = "active"
        var activityState: String = "active"
        var isDisplayAsleep: Bool = false
        var isScreenLocked: Bool = false
        /// IOSurface 帧渲染器（每显示器），用于帧通道回调
        var ioSurfaceRenderers: [UInt32: IOSurfaceFrameRenderer] = [:]
        var ioSurfaceRendererGenerations: [UInt32: UUID] = [:]
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    private init() {
        // 注册库变化通知 — 收到通知时清除缓存
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let state = Unmanaged<WallpaperState>.fromOpaque(observer).takeUnretainedValue()
                state.clearCaches()
            },
            "com.waifux.app.wallpaper.prefsChanged" as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// 清除缓存的 URL，使下次查找重新评估当前库。
    func clearCaches() {
        lock.withLock { state in
            state.cachedVideoURL = nil
            state.cachedImageURL = nil
            state.cachedThumbnailURL = nil
        }
    }

    // MARK: - Context Management

    /// 存储新的渲染上下文。如果同一 wallpaperID 已有渲染器，先停止并返回旧的。
    func storeContext(_ context: ActiveWallpaper, id: UInt32, wallpaperID: String?) -> ActiveWallpaper? {
        lock.withLock { state in
            var existing: ActiveWallpaper?
            if let wid = wallpaperID, let oldId = state.wallpaperIDToContext[wid] {
                existing = state.activeContexts.removeValue(forKey: oldId)
            }
            state.activeContexts[id] = context
            if let wid = wallpaperID {
                state.wallpaperIDToContext[wid] = id
            }
            return existing
        }
    }

    func removeContext(wallpaperID: String) -> ActiveWallpaper? {
        lock.withLock { state in
            guard let contextId = state.wallpaperIDToContext.removeValue(forKey: wallpaperID) else { return nil }
            return state.activeContexts.removeValue(forKey: contextId)
        }
    }

    func removeAllContexts() -> [ActiveWallpaper] {
        let removed = lock.withLock { state -> ([ActiveWallpaper], [IOSurfaceFrameRenderer]) in
            let all = Array(state.activeContexts.values)
            let ioRenderers = Array(state.ioSurfaceRenderers.values)
            state.activeContexts.removeAll()
            state.wallpaperIDToContext.removeAll()
            state.ioSurfaceRenderers.removeAll()
            state.ioSurfaceRendererGenerations.removeAll()
            return (all, ioRenderers)
        }
        for ctx in removed.0 { ctx.renderer?.stop() }
        for renderer in removed.1 { renderer.stop() }
        return removed.0
    }

    // MARK: - Iteration

    func forEachRenderer(_ body: (VideoRenderer) -> Void) {
        let renderers = lock.withLock { $0.activeContexts.values.compactMap(\.renderer) }
        for renderer in renderers { body(renderer) }
    }

    /// 对指定 displayID 的渲染器执行闭包
    func forRenderers(displayID: UInt32, _ body: (VideoRenderer) -> Void) {
        let renderers = lock.withLock {
            $0.activeContexts.values
                .filter { $0.displayID == displayID }
                .compactMap(\.renderer)
        }
        for renderer in renderers { body(renderer) }
    }

    /// 遍历每个活跃 context 的 renderer 和 displayID（用于 per-display policy）
    func forEachActiveContext(_ body: (UInt32?, VideoRenderer) -> Void) {
        let contexts = lock.withLock { Array($0.activeContexts.values) }
        for ctx in contexts {
            if let renderer = ctx.renderer {
                body(ctx.displayID, renderer)
            }
        }
    }

    /// 根据 displayID 查找活跃 renderer
    func renderer(for displayID: UInt32) -> VideoRenderer? {
        lock.withLock {
            $0.activeContexts.values.first(where: { $0.displayID == displayID })?.renderer
        }
    }

    func activeContext(for displayID: UInt32) -> ActiveWallpaper? {
        lock.withLock {
            $0.activeContexts.values.first(where: { $0.displayID == displayID })
        }
    }

    func activeContextForCommand(displayID: UInt32) -> ActiveWallpaper? {
        lock.withLock { state in
            if let exact = state.activeContexts.values.first(where: { $0.displayID == displayID }) {
                return exact
            }
            if let unbound = state.activeContexts.values.first(where: { $0.displayID == nil }) {
                return unbound
            }
            if state.activeContexts.count == 1 {
                return state.activeContexts.values.first
            }
            return nil
        }
    }

    func activeContext(wallpaperID: String) -> ActiveWallpaper? {
        lock.withLock { state in
            guard let contextId = state.wallpaperIDToContext[wallpaperID] else { return nil }
            return state.activeContexts[contextId]
        }
    }

    func updateContextDisplayID(wallpaperID: String, displayID: UInt32) {
        lock.withLock { state in
            guard let contextId = state.wallpaperIDToContext[wallpaperID],
                  let old = state.activeContexts[contextId],
                  old.displayID != displayID else {
                return
            }
            state.activeContexts[contextId] = ActiveWallpaper(
                caContext: old.caContext,
                rootLayer: old.rootLayer,
                renderer: old.renderer,
                displayID: displayID,
                videoID: old.videoID
            )
        }
    }

    func activeContextsSnapshot() -> [ActiveWallpaper] {
        lock.withLock { Array($0.activeContexts.values) }
    }

    func replaceContextRenderer(displayID: UInt32, renderer: VideoRenderer?, videoID: String?) -> VideoRenderer? {
        lock.withLock { state in
            guard let pair = state.activeContexts.first(where: { $0.value.displayID == displayID }) else {
                return nil
            }
            let old = pair.value
            state.activeContexts[pair.key] = ActiveWallpaper(
                caContext: old.caContext,
                rootLayer: old.rootLayer,
                renderer: renderer,
                displayID: old.displayID,
                videoID: videoID ?? old.videoID
            )
            return old.renderer
        }
    }

    func replaceContextRendererForCommand(displayID: UInt32, renderer: VideoRenderer?, videoID: String?) -> VideoRenderer? {
        lock.withLock { state in
            let pair = state.activeContexts.first(where: { $0.value.displayID == displayID })
                ?? state.activeContexts.first(where: { $0.value.displayID == nil })
                ?? (state.activeContexts.count == 1 ? state.activeContexts.first : nil)
            guard let pair else { return nil }
            let old = pair.value
            state.activeContexts[pair.key] = ActiveWallpaper(
                caContext: old.caContext,
                rootLayer: old.rootLayer,
                renderer: renderer,
                displayID: displayID,
                videoID: videoID ?? old.videoID
            )
            return old.renderer
        }
    }

    // MARK: - IOSurfaceFrameRenderer Registry

    /// 存储 IOSurfaceFrameRenderer 供帧通道回调使用
    func storeIOSurfaceRenderer(_ renderer: IOSurfaceFrameRenderer, generation: UUID, for displayID: UInt32) {
        let previous = lock.withLock { state -> IOSurfaceFrameRenderer? in
            let old = state.ioSurfaceRenderers[displayID]
            state.ioSurfaceRenderers[displayID] = renderer
            state.ioSurfaceRendererGenerations[displayID] = generation
            return old
        }
        previous?.stop()
    }

    /// 移除 IOSurfaceFrameRenderer
    func removeIOSurfaceRenderer(for displayID: UInt32) {
        let previous = lock.withLock { state -> IOSurfaceFrameRenderer? in
            let old = state.ioSurfaceRenderers[displayID]
            state.ioSurfaceRenderers[displayID] = nil
            state.ioSurfaceRendererGenerations[displayID] = nil
            return old
        }
        previous?.stop()
    }

    /// 获取指定显示器的 IOSurfaceFrameRenderer
    func ioSurfaceRenderer(for displayID: UInt32) -> IOSurfaceFrameRenderer? {
        lock.withLock { $0.ioSurfaceRenderers[displayID] }
    }

    func isCurrentIOSurfaceRendererGeneration(_ generation: UUID, for displayID: UInt32) -> Bool {
        lock.withLock { $0.ioSurfaceRendererGenerations[displayID] == generation }
    }

    /// 获取任意一个活跃的 IOSurfaceFrameRenderer（用于 snapshot 回退）。
    func anyIOSurfaceRenderer() -> IOSurfaceFrameRenderer? {
        lock.withLock { $0.ioSurfaceRenderers.values.first }
    }

    /// 所有活跃 context 的唯一 displayID 集合
    func uniqueDisplayIDs() -> Set<UInt32> {
        lock.withLock { Set($0.activeContexts.values.compactMap(\.displayID)) }
    }

    /// 每个唯一显示器的活跃 context 信息
    func activeDisplayContexts() -> [(displayID: UInt32, videoID: String?)] {
        lock.withLock { state in
            var seen = Set<UInt32>()
            var result: [(displayID: UInt32, videoID: String?)] = []
            for ctx in state.activeContexts.values {
                guard let did = ctx.displayID, seen.insert(did).inserted else { continue }
                result.append((displayID: did, videoID: ctx.videoID))
            }
            return result
        }
    }

    var activeContextCount: Int {
        lock.withLock { $0.activeContexts.count }
    }

    // MARK: - Properties

    var cachedThumbnailURL: URL? {
        get { lock.withLock { $0.cachedThumbnailURL } }
        set { lock.withLock { $0.cachedThumbnailURL = newValue } }
    }

    var cacheDirectoryURL: URL? {
        get { lock.withLock { $0.cacheDirectoryURL } }
        set { lock.withLock { $0.cacheDirectoryURL = newValue } }
    }

    var cachedVideoURL: URL? {
        get { lock.withLock { $0.cachedVideoURL } }
        set { lock.withLock { $0.cachedVideoURL = newValue } }
    }

    var cachedImageURL: URL? {
        get { lock.withLock { $0.cachedImageURL } }
        set { lock.withLock { $0.cachedImageURL = newValue } }
    }

    var currentVideoID: String? {
        get { lock.withLock { $0.currentVideoID } }
        set {
            lock.withLock { $0.currentVideoID = newValue }
            UserDefaults.standard.set(newValue, forKey: WallpaperState.selectedVideoKey)
        }
    }

    var presentationMode: String {
        get { lock.withLock { $0.presentationMode } }
        set { lock.withLock { $0.presentationMode = newValue } }
    }

    var activityState: String {
        get { lock.withLock { $0.activityState } }
        set { lock.withLock { $0.activityState = newValue } }
    }

    var isDisplayAsleep: Bool {
        get { lock.withLock { $0.isDisplayAsleep } }
        set { lock.withLock { $0.isDisplayAsleep = newValue } }
    }

    var isScreenLocked: Bool {
        get { lock.withLock { $0.isScreenLocked } }
        set { lock.withLock { $0.isScreenLocked = newValue } }
    }
}
