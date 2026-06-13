import AppKit
import SwiftUI
import Combine
import MetalKit
import CoreText
import JavaScriptCore

// MARK: - 液态玻璃时钟 Overlay 管理器
//
// 为每个屏幕创建透明 NSWindow，在桌面壁纸层之上渲染
// 场景 sidecar 中的动态文本对象。配合烘焙场景壁纸使用。
//
// ═══════════════════════════════════════════════════════════
// 架构：
//   LiquidGlassClockOverlayManager (单例)
//     ├─ 监听 LiquidGlassClockSettings.shared.$config
//     ├─ 监听 VideoWallpaperManager.shared 状态
//     │    （视频壁纸暂停时→暂停渲染，停止时→隐藏时钟）
//     ├─ 每秒定时器驱动 MTKView 重绘
//     ├─ 为每个 NSScreen 创建/管理 NSWindow
//     │    └─ window.level = desktopWindow + 2
//     │         （比颗粒蒙层 desktopWindow + 1 高一层）
//     └─ 刷新策略：Space 切换→更新、屏幕插拔→重建
//
//  性能优化：
//   - MTKView preferredFramesPerSecond=1（时钟只需 1fps）
//   - shouldRedraw() 检查分钟变化，不变则不提交渲染
//   - 视频暂停时自动暂停 Metal 渲染
//   - 时钟窗口隐藏时冻结全部渲染
//
//  未来自定义参数扩展口：
//   - 多显示器独立配置（每屏不同位置/格式）
//   - 点击穿透区域自定义
//   - 鼠标悬停交互（显示额外信息）
//   - 快捷键临时隐藏
// ═══════════════════════════════════════════════════════════

@MainActor
public final class LiquidGlassClockOverlayManager {
    public static let shared = LiquidGlassClockOverlayManager()

    // MARK: - 每屏时钟窗口

    /// key = screenID (NSScreen.wallpaperScreenIdentifier)
    private var clockWindows: [String: NSWindow] = [:]

    /// 当前配置缓存（用于比对变化）
    private var currentConfig: LiquidGlassClockConfiguration = .init()

    /// 每秒定时器，驱动时钟刷新
    private var clockTickTimer: Timer?

    /// 各屏幕对应的 MTKView 引用（用于暂停/恢复）
    private var metalViews: [String: MTKView] = [:]

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Dock 安全区域监听
        setupDockObserver()

        // 监听配置变化 → 刷新所有窗口
        LiquidGlassClockSettings.shared.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newConfig in
                self?.onConfigChanged(newConfig)
            }
            .store(in: &cancellables)

        // 监听视频壁纸暂停状态 → 同步暂停 Metal 渲染
        VideoWallpaperManager.shared.$isPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPaused in
                self?.onVideoPausedChanged(isPaused)
            }
            .store(in: &cancellables)

        // 监听视频壁纸切换 → 自动显示/隐藏/更新时钟
        VideoWallpaperManager.shared.$currentVideoURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.onVideoWallpaperStateChanged()
            }
            .store(in: &cancellables)

        // 第二道保障：订阅壁纸变更计数器，确保任何壁纸切换后 overlay 都刷新
        // 即使 `currentVideoURL` 值不变（如：同一 URL 重新应用），此计数器也会自增。
        VideoWallpaperManager.shared.$wallpaperChangeCount
            .receive(on: DispatchQueue.main)
            .dropFirst()  // 跳过初始值 0
            .sink { [weak self] _ in
                self?.onVideoWallpaperStateChanged()
            }
            .store(in: &cancellables)

        // 监听 Space 切换（延迟确保层级正确）
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let self = self, LiquidGlassClockSettings.shared.config.enabled else { return }
                    for (_, window) in self.clockWindows {
                        window.orderFront(nil)
                    }
                }
            }
            .store(in: &cancellables)

        // 监听屏幕配置变化（外接显示器插拔）
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.rebuildAll()
                }
            }
            .store(in: &cancellables)
    }

    nonisolated deinit {
        // Combine cancellables 自动清理
    }

    // MARK: - 公开方法

    /// 立即刷新所有屏幕的时钟窗口（外部调用，如热键切换、壁纸切换）
    public func refreshAll() {
        let config = LiquidGlassClockSettings.shared.config
        if shouldShowClock(config: config) {
            if clockWindows.isEmpty {
                createWindowsForAllScreens(config: config)
            } else {
                // 窗口已存在时也必须更新内容（壁纸切换时 sidecar 数据已变化）
                updateAllWindows(config: config)
            }
            if config.enabled {
                startClockTimer()
            } else {
                stopClockTimer()
            }
        } else {
            destroyAllWindows()
            stopClockTimer()
        }
        currentConfig = config
        // 确保所有窗口置前
        for (_, window) in clockWindows {
            window.orderFront(nil)
        }
    }

    /// 强制销毁所有窗口并重建（屏幕配置变化时）
    public func rebuildAll() {
        destroyAllWindows()
        let config = LiquidGlassClockSettings.shared.config
        if shouldShowClock(config: config) {
            createWindowsForAllScreens(config: config)
        }
    }

    // MARK: - 视频壁纸状态联动

    /// 视频壁纸暂停/恢复 → 暂停/恢复 Metal 渲染
    private func onVideoPausedChanged(_ isPaused: Bool) {
        guard currentConfig.enabled, currentConfig.metalShaderEnabled else { return }
        for (_, mtkView) in metalViews {
            LiquidGlassMetalRenderer.shared.setPaused(isPaused, view: mtkView)
        }
    }

    /// 检查当前视频壁纸是否有关联的动态文本 sidecar
    private func currentVideoHasDynamicText() -> Bool {
        guard let videoURL = VideoWallpaperManager.shared.currentVideoURL else { return false }
        return WallpaperDynamicTextParser.hasDynamicText(for: videoURL)
    }

    private func currentDynamicTextInfo() -> WallpaperDynamicTextsInfo? {
        guard VideoWallpaperManager.shared.isVideoWallpaperActive,
              let videoURL = VideoWallpaperManager.shared.currentVideoURL
        else { return nil }
        guard let info = WallpaperDynamicTextParser.loadSidecar(for: videoURL) else { return nil }
        if let wallpaperPath = info.wallpaperPath, !wallpaperPath.isEmpty {
            return SceneWallpaperDesignService.mergeDesign(into: info, wallpaperPath: wallpaperPath)
        }
        return info
    }

    /// 视频壁纸激活状态变化 → 检查 sidecar JSON + 总开关，仅当允许时才创建时钟
    private func onVideoWallpaperStateChanged() {
        let videoActive = VideoWallpaperManager.shared.isVideoWallpaperActive
        let config = LiquidGlassClockSettings.shared.config

        // 总开关关闭时，不显示任何桌面动态元素
        guard config.enabled else {
            destroyAllWindows()
            return
        }

        if videoActive {
            // 仅当烘焙视频有关联的动态文本 sidecar 时才显示时钟
            guard currentVideoHasDynamicText() else {
                destroyAllWindows()
                return
            }
            if clockWindows.isEmpty {
                createWindowsForAllScreens(config: config)
            } else {
                updateAllWindows(config: config)
            }
            if config.showAudioVisualizer {
                SystemAudioCaptureService.shared.start()
            }
        } else {
            destroyAllWindows()
        }
    }

    /// 判断是否应创建时钟窗口（检查 sidecar + enabled）
    private func shouldShowClock() -> Bool {
        shouldShowClock(config: LiquidGlassClockSettings.shared.config)
    }

    private func shouldShowClock(config: LiquidGlassClockConfiguration) -> Bool {
        guard config.enabled else { return false }
        // 仅在有视频壁纸且关联 sidecar 有时钟文本时才显示 overlay
        guard VideoWallpaperManager.shared.isVideoWallpaperActive,
              let videoURL = VideoWallpaperManager.shared.currentVideoURL
        else { return false }
        return WallpaperDynamicTextParser.hasDynamicText(for: videoURL)
    }

    // MARK: - 定时器管理

    /// 启动每秒定时器（驱动 MTKView 重绘 + SwiftUI 时钟更新）
    private func startClockTimer() {
        guard clockTickTimer == nil else { return }
        clockTickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.currentConfig.enabled else { return }

                // 轮询检测 Dock 区域变化（兜底：Dock 位置改变等无通知的变更）
                self.pollDockInsets()

                if self.currentConfig.metalShaderEnabled {
                    // Metal 路径：手动触发重绘（shouldRedraw 内部会跳过无效帧）
                    for (_, mtkView) in self.metalViews {
                        LiquidGlassMetalRenderer.shared.requestRedraw(view: mtkView)
                    }
                }
            }
        }
    }

    private func stopClockTimer() {
        clockTickTimer?.invalidate()
        clockTickTimer = nil
    }

    // MARK: - 配置变化处理

    private func onConfigChanged(_ newConfig: LiquidGlassClockConfiguration) {
        let wasEnabled = currentConfig.enabled

        // 音频柱状图开关变化 → 启停系统音频捕获
        if newConfig.showAudioVisualizer != currentConfig.showAudioVisualizer {
            if newConfig.showAudioVisualizer && newConfig.enabled {
                SystemAudioCaptureService.shared.start()
            } else if !newConfig.showAudioVisualizer {
                SystemAudioCaptureService.shared.stop()
            }
        }

        if newConfig.enabled != wasEnabled {
            if newConfig.enabled {
                // 检查 sidecar：有视频壁纸时只在该壁纸有动态文本时创建
                if shouldShowClock(config: newConfig) {
                    createWindowsForAllScreens(config: newConfig)
                }
                // 启动音频捕获（如果启用了柱状图）
                if newConfig.showAudioVisualizer {
                    SystemAudioCaptureService.shared.start()
                }
                startClockTimer()
            } else {
                // 关闭桌面动态元素时，销毁所有窗口（包括 sidecar 补偿层）
                destroyAllWindows()
                stopClockTimer()
                // 关闭时钟时也停止音频捕获
                SystemAudioCaptureService.shared.stop()
            }
        } else if shouldShowClock(config: newConfig) {
            // 已启用→检查是否需要更新
            if newConfig != currentConfig {
                updateAllWindows(config: newConfig)
            }
        }
        currentConfig = newConfig
    }

    // MARK: - 窗口管理

    private func applyConfig(_ config: LiquidGlassClockConfiguration) {
        if shouldShowClock(config: config) {
            // 检查 sidecar：有视频壁纸时只在该壁纸有动态文本时创建
            createWindowsForAllScreens(config: config)
            if config.enabled {
                startClockTimer()
            } else {
                stopClockTimer()
            }
        } else {
            destroyAllWindows()
            stopClockTimer()
        }
        currentConfig = config
    }

    /// 为所有屏幕创建时钟窗口
    private func createWindowsForAllScreens(config: LiquidGlassClockConfiguration) {
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            guard clockWindows[screenID] == nil else {
                continue
            }
            createWindow(for: screen, config: config)
        }
    }

    /// 为指定屏幕创建单个时钟窗口
    private func createWindow(for screen: NSScreen, config: LiquidGlassClockConfiguration) {
        let screenID = screen.wallpaperScreenIdentifier
        let frame = screen.frame

        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.setFrame(frame, display: true)
        window.title = "WaifuX Dynamic Text Overlay"
        // 桌面层级 +20：压过视频壁纸窗口，仍保持在普通应用窗口之下
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 20)
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .transient
        ]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.acceptsMouseMovedEvents = false

        // 构建时钟视图并包装到 NSHostingView
        let clockView = makeClockView(for: screen, config: config, screenID: screenID)
        let hostingView = NSHostingView(rootView: clockView)
        hostingView.frame = CGRect(origin: .zero, size: frame.size)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        window.contentView = hostingView

        clockWindows[screenID] = window
        window.orderFront(nil)
    }

    /// 更新所有现有窗口的配置
    private func updateAllWindows(config: LiquidGlassClockConfiguration) {
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            updateWindow(for: screen, screenID: screenID, config: config)
        }
    }

    /// 更新单个屏幕的窗口内容
    private func updateWindow(for screen: NSScreen, screenID: String? = nil, config: LiquidGlassClockConfiguration) {
        let sid = screenID ?? screen.wallpaperScreenIdentifier
        guard let window = clockWindows[sid] else { return }

        let clockView = makeClockView(for: screen, config: config, screenID: sid)
        let hostingView = NSHostingView(rootView: clockView)
        hostingView.frame = CGRect(origin: .zero, size: screen.frame.size)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        window.contentView = hostingView
        window.orderFront(nil)
    }

    /// 销毁所有屏幕的时钟窗口
    private func destroyAllWindows() {
        for (screenID, window) in clockWindows {
            window.orderOut(nil)
            window.contentView = nil
            clockWindows.removeValue(forKey: screenID)
        }
        metalViews.removeAll()
    }

    // MARK: - 时钟视图构建

    /// Dock 当前安全区域（响应式，随 Dock 显隐/位置变化自动变化）
    @Published private var dockInsets: DockInfo = .zero
    private var dockCancellables = Set<AnyCancellable>()
    /// 上次触发刷新时的 Dock 区域，用于轮询检测变化
    private var lastDockInsetsForRefresh: DockInfo = .zero

    /// 初始化 Dock 监听
    private func setupDockObserver() {
        // 初始值
        dockInsets = DockInfo.current()
        lastDockInsetsForRefresh = dockInsets

        // 监听 Dock 显隐通知
        let nc = NSWorkspace.shared.notificationCenter
        nc.publisher(for: NSNotification.Name("NSWorkspaceDidHideDockNotification"))
            .merge(with: nc.publisher(for: NSNotification.Name("NSWorkspaceDidUnhideDockNotification")))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.dockInsets = DockInfo.current()
                self.lastDockInsetsForRefresh = self.dockInsets
                self.updateAllWindows(config: LiquidGlassClockSettings.shared.config)
            }
            .store(in: &dockCancellables)

        // 监听屏幕参数变化（分辨率、排列、Dock 位置改变等）
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.dockInsets = DockInfo.current()
                self.lastDockInsetsForRefresh = self.dockInsets
                self.updateAllWindows(config: LiquidGlassClockSettings.shared.config)
            }
            .store(in: &dockCancellables)

        // 监听 Dock 位置变化分布式通知（用户手动改 Dock 位置时）
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDockDidChangePosition),
            name: NSNotification.Name("com.apple.dock.positionchanged"),
            object: nil
        )
    }

    @objc private func handleDockDidChangePosition() {
        let newInsets = DockInfo.current()
        guard newInsets != dockInsets else { return }
        dockInsets = newInsets
        lastDockInsetsForRefresh = dockInsets
        updateAllWindows(config: LiquidGlassClockSettings.shared.config)
    }

    /// 在 clock tick 中轮询检测 Dock 区域变化（兜底，覆盖所有未捕获的变更）
    private func pollDockInsets() {
        let current = DockInfo.current()
        guard current != lastDockInsetsForRefresh else { return }
        dockInsets = current
        lastDockInsetsForRefresh = current
        updateAllWindows(config: LiquidGlassClockSettings.shared.config)
    }

    /// 构建适配指定屏幕的时钟视图（含位置计算）
    private func makeClockView(for screen: NSScreen, config: LiquidGlassClockConfiguration, screenID: String = "") -> some View {
        let sidecarInfo = currentDynamicTextInfo()
        let rawEntries = sidecarInfo?.entries.filter { entry in
            guard entry.visible else { return false }
            // 未知行为的条目必须有实际文本内容才渲染，否则跳过（避免空白占位）
            if entry.behavior == "unknown" {
                guard let value = entry.value, !value.isEmpty else { return false }
            }
            return entry.finalOriginX != nil || entry.originX != nil || entry.finalX != nil ||
                   entry.finalOriginY != nil || entry.originY != nil || entry.finalY != nil
        } ?? []

        // 按位置去重：多语言壁纸同一位置有多个语言版本的文本，只保留一个
        let rendererEntries = Self.deduplicateByPosition(rawEntries)

        if !rendererEntries.isEmpty {
            return AnyView(
                RendererDynamicTextOverlayView(
                    entries: rendererEntries,
                    sceneWidth: sidecarInfo?.sceneWidth,
                    sceneHeight: sidecarInfo?.sceneHeight,
                    screenSize: screen.frame.size,
                    dockInsets: dockInsets
                )
            )
        }

        // 没有 sidecar 文本条目时，不显示任何默认时钟
        return AnyView(Color.clear.ignoresSafeArea())
    }

    /// 按位置去重：位置相近（5 scene units 以内）的条目视为同一位置的多语言版本，仅保留一个。
    /// 保留策略：选择 renderOrder 更大的（即上层叠加的），避免阴影/描边层（通常 renderOrder 小、颜色暗）
    /// 被保留而主文本层被丢弃导致文字不可见。
    private static func deduplicateByPosition(_ entries: [DynamicTextEntry]) -> [DynamicTextEntry] {
        var result: [DynamicTextEntry] = []
        for entry in entries {
            let ex = entry.finalOriginX ?? entry.originX ?? 0
            let ey = entry.finalOriginY ?? entry.originY ?? 0
            let existingIndex = result.firstIndex { existing in
                let xx = existing.finalOriginX ?? existing.originX ?? 0
                let yy = existing.finalOriginY ?? existing.originY ?? 0
                return abs(xx - ex) < 5 && abs(yy - ey) < 5
            }
            if let idx = existingIndex {
                // 位置重复时，保留 renderOrder 更大的（上层），丢弃下层（如阴影层）
                if (entry.renderOrder ?? 0) > (result[idx].renderOrder ?? 0) {
                    result[idx] = entry
                }
            } else {
                result.append(entry)
            }
        }
        return result
    }

    // MARK: - 通知处理

    @objc private func handleSpaceChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, LiquidGlassClockSettings.shared.config.enabled else { return }
            // Space 切换后重新 orderFront，确保层级正确
            for (_, window) in self.clockWindows {
                window.orderFront(nil)
            }
        }
    }

    @objc private func handleScreenParametersChanged() {
        // 屏幕配置变化后重建所有窗口
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.rebuildAll()
        }
    }

    // MARK: - 屏幕 ID 辅助

    /// 获取窗口对应的屏幕（预留：用于多屏独立配置）
    public func screen(for window: NSWindow) -> NSScreen? {
        NSScreen.screens.first { $0.wallpaperScreenIdentifier == clockWindows.first(where: { $0.value == window })?.key }
    }
}

// NSScreen.wallpaperScreenIdentifier 定义在 Utilities/NSScreen+Wallpaper.swift
// 此处直接使用已有扩展

// MARK: - Dock 安全区域

/// 当前 Dock 的位置和尺寸
private struct DockInfo: Equatable {
    var bottom: CGFloat = 0
    var left: CGFloat = 0
    var right: CGFloat = 0

    static let zero = DockInfo()

    /// 从主屏幕的 frame/visibleFrame 差值计算 Dock 占用区域
    static func current() -> DockInfo {
        guard let screen = NSScreen.main else { return .zero }
        let frame = screen.frame
        let visible = screen.visibleFrame
        var info = DockInfo()
        // bottom Dock: visible 的 Y 起点比 frame 高
        if visible.origin.y > frame.origin.y {
            info.bottom = visible.origin.y - frame.origin.y
        }
        // left Dock: visible 的 X 起点比 frame 靠右
        if visible.origin.x > frame.origin.x {
            info.left = visible.origin.x - frame.origin.x
        }
        // right Dock: visible 的右边界比 frame 小
        let frameRight = frame.origin.x + frame.width
        let visibleRight = visible.origin.x + visible.width
        if frameRight > visibleRight {
            info.right = frameRight - visibleRight
        }
        return info
    }
}

private struct RendererDynamicTextOverlayView: View {
    let entries: [DynamicTextEntry]
    let sceneWidth: Double?
    let sceneHeight: Double?
    let screenSize: CGSize
    let dockInsets: DockInfo

    @State private var now = Date()

    private let timer = Timer.publish(every: 1, tolerance: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.ignoresSafeArea()
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                RendererDynamicTextView(
                    entry: entry,
                    now: now,
                    fontSize: computeFontSize(for: entry)
                )
                .position(position(for: entry))
                .zIndex(Double(entry.renderOrder ?? 0))
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .onReceive(timer) { now = $0 }
    }

    /// 按 C++ FreeType 实际渲染尺寸计算 SwiftUI pt 字号
    /// 基于 rasterHeight（pixelSize × scaleY），经验修正因子 2.0 补偿
    /// FreeType 的 ascent + descent + padding 使纹理高度大于 pixelSize。
    private func computeFontSize(for entry: DynamicTextEntry) -> CGFloat {
        let sourceHeight = sceneHeight ?? Double(screenSize.height)
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0

        if let rh = entry.rasterHeight, rh > 0 {
            // rasterHeight 仅含 pixelSize × scaleY，实际 FreeType 纹理高度
            // 约为 pixelSize × 2.0（含 ascent + descent + padding×2）。
            // 直接放大 2× 匹配 C++ 渲染尺寸。
            let sceneTextHeight = rh * 2.0
            let screenPx = sceneTextHeight / max(sourceHeight, 1) * Double(screenSize.height)
            return CGFloat(screenPx / Double(screenScale))
        }

        // 保底：用 effectiveFontSize × multiplier
        let isDay = (entry.name.lowercased().contains("day")
                     || entry.name.contains("D a y"))
        let multiplier: Double = isDay ? 5.0 : 3.0
        let sceneTextHeight = (entry.effectiveFontSize ?? entry.fontSize ?? 32) * multiplier
        let screenPx = sceneTextHeight / max(sourceHeight, 1) * Double(screenSize.height)
        return CGFloat(screenPx / Double(screenScale))
    }

    private func position(for entry: DynamicTextEntry) -> CGPoint {
        let sourceWidth = sceneWidth ?? Double(screenSize.width)
        let sourceHeight = sceneHeight ?? Double(screenSize.height)
        // finalOriginX/finalOriginY 是左下角原点(OpenGL)坐标系：
        //   X: 0=左侧, sceneWidth=右侧
        //   Y: 0=底部, sceneHeight=顶部
        // 需要转换到 SwiftUI 的左上角原点 Y-向下坐标系
        let rawX = entry.finalOriginX ?? entry.originX ?? entry.finalX ?? 0
        let rawY = entry.finalOriginY ?? entry.originY ?? entry.finalY ?? 0

        // 考虑 Dock 安全区域：将场景坐标映射到排除 Dock 后的可用区域
        let availW = Double(screenSize.width) - Double(dockInsets.left) - Double(dockInsets.right)
        let availH = Double(screenSize.height) - Double(dockInsets.bottom)
        let x = Double(dockInsets.left) + rawX / max(sourceWidth, 1) * availW
        let y = (1 - rawY / max(sourceHeight, 1)) * availH
        return CGPoint(x: x, y: y)
    }
}

private struct RendererDynamicTextView: View {
    let entry: DynamicTextEntry
    let now: Date
    let fontSize: CGFloat

    var body: some View {
        Text(renderedText)
            .font(font)
            .foregroundStyle(color)
            .opacity(entry.alpha ?? 1)
            .multilineTextAlignment(textAlignment)
            .lineLimit(nil)
            .fixedSize()
            .rotationEffect(.radians(entry.finalAngle ?? entry.rotation ?? 0))
            // effectiveFontSize 已包含 scale，不做二次 scaleEffect
            .allowsHitTesting(false)
    }

    private var renderedText: String {
        let runtimeBehavior = entry.runtimeBehaviorOverride ?? entry.behavior
        let runtimeScript = entry.runtimeScriptOverride ?? entry.script
        let runtimePropertiesJSON = entry.runtimeScriptPropertiesJSONOverride ?? entry.scriptPropertiesJSON

        if runtimeBehavior == "date", let languageCode = entry.runtimeLanguageCodeOverride {
            return Self.localizedDateText(from: now, languageCode: languageCode)
        }

        // 对于有时间类脚本的条目，用 JavaScriptCore 重新执行脚本获取当前时间
        if let script = runtimeScript, !script.isEmpty,
           runtimeBehavior == "clock" || runtimeBehavior == "date" || runtimeBehavior == "weekday" {
            if let result = Self.executeWallpaperScript(script, scriptPropertiesJSON: runtimePropertiesJSON) {
                return result
            }
        }

        // 非时间类或脚本执行失败时，使用 stale resolvedText
        if let resolved = entry.resolvedText, !resolved.isEmpty {
            return resolved
        }

        // 根据条目名称是否含中文选择对应语言的 formatter
        let useChinese = Self.isChineseName(entry.name)

        switch runtimeBehavior {
        case "clock":
            return Self.formattedClock(from: now, format: entry.format)
        case "weekday":
            let formatter = useChinese ? Self.chineseWeekdayFormatter : Self.weekdayFormatter
            let raw = formatter.string(from: now)
            // C++ renderer 对 Day 对象会加空格: "W E D N E S D A Y"
            let name = entry.name.lowercased().replacingOccurrences(of: " ", with: "")
            if !useChinese {
                if name == "day" || name.contains("day") {
                    return raw.uppercased().map { String($0) }.joined(separator: "  ")
                }
                return raw.uppercased()
            }
            return raw
        case "date":
            let formatter = useChinese ? Self.chineseDateFormatter : Self.dateFormatter
            return formatter.string(from: now)
        case "period":
            return Self.formattedPeriod(from: now)
        default:
            return entry.value ?? ""
        }
    }

    private static func localizedDateText(from date: Date, languageCode: String) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day, .month, .year], from: date)
        let day = components.day ?? 1
        let month = max(1, min(12, components.month ?? 1))
        let year = components.year ?? 1970
        let monthText = localizedMonthText(month: month, languageCode: languageCode)

        switch languageCode.uppercased() {
        case "JP", "JA":
            return "\(year)年\(month)月\(day)日"
        default:
            return "\(day) \(monthText) \(year)"
        }
    }

    private static func localizedMonthText(month: Int, languageCode: String) -> String {
        let index = month - 1
        let months: [String]
        switch languageCode.uppercased() {
        case "RU":
            months = ["ЯН", "ФЕ", "МА", "АП", "МА", "ИЮ", "ИЮ", "АВ", "СЕ", "ОК", "НО", "ДЕ"]
        case "FR":
            months = ["JAN", "FEV", "MAR", "AVR", "MAI", "JUIN", "JUIL", "AOUT", "SEP", "OCT", "NOV", "DEC"]
        case "ES":
            months = ["ENE", "FEB", "MAR", "ABR", "MAY", "JUN", "JUL", "AGO", "SEP", "OCT", "NOV", "DIC"]
        case "JP", "JA":
            return String(month)
        default:
            months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        }
        return months.indices.contains(index) ? months[index] : months[0]
    }

    /// 根据当前时间返回中文时段文本
    private static func formattedPeriod(from date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 0:      return "午夜"
        case 1..<7:  return "凌晨"
        case 7..<12: return "早上"
        case 12:     return "正午"
        case 13..<18: return "下午"
        case 18:     return "傍晚"
        default:     return "晚上"
        }
    }

    /// 根据 format 格式化时钟时间组件
    /// - Parameters:
    ///   - format: 格式描述，如 "hh"（时）、"mm"（分）、"ss"（秒）、"hh:mm"（完整时间）
    ///              nil 时回退到完整时间 "HH:mm"
    private static func formattedClock(from date: Date, format: String?) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute, .second], from: date)

        guard let fmt = format?.lowercased(), !fmt.isEmpty else {
            // 无格式信息，回退到完整时间
            return clockFormatter.string(from: date)
        }

        switch fmt {
        case "hh":
            return String(format: "%02d", comps.hour ?? 0)
        case "h":
            return "\(comps.hour ?? 0)"
        case "mm":
            return String(format: "%02d", comps.minute ?? 0)
        case "m":
            return "\(comps.minute ?? 0)"
        case "ss":
            return String(format: "%02d", comps.second ?? 0)
        case "s":
            return "\(comps.second ?? 0)"
        default:
            // 将 format 中的 hh/h/mm/m/ss/s 替换为实际值
            var result = fmt
            // 总是替换已知的时间组件占位符
            result = result.replacingOccurrences(of: "hh", with: String(format: "%02d", comps.hour ?? 0))
            if !fmt.contains("hh") {
                result = result.replacingOccurrences(of: "h", with: "\(comps.hour ?? 0)")
            }
            result = result.replacingOccurrences(of: "mm", with: String(format: "%02d", comps.minute ?? 0))
            if !fmt.contains("mm") {
                result = result.replacingOccurrences(of: "m", with: "\(comps.minute ?? 0)")
            }
            result = result.replacingOccurrences(of: "ss", with: String(format: "%02d", comps.second ?? 0))
            if !fmt.contains("ss") {
                result = result.replacingOccurrences(of: "s", with: "\(comps.second ?? 0)")
            }
            if result == fmt {
                return clockFormatter.string(from: date)
            }
            return result
        }
    }

    /// 字体：按 C++ FreeType 实际尺寸计算的字号，优先 fontPath → fontFamily → system
    private var font: Font {
        // 1. 有 fontPath 时从文件注册加载
        if let path = entry.fontPath, !path.isEmpty,
           let psName = Self.registeredPSName(path: path) {
            return .custom(psName, size: fontSize)
        }

        // 2. 通过 fontFamily 名称加载（处理 systemfont_<name> 约定）
        if let family = entry.fontFamily, !family.isEmpty {
            let fontName: String
            if family.lowercased().hasPrefix("systemfont_") {
                fontName = String(family.dropFirst("systemfont_".count))
            } else {
                fontName = family
            }
            if !fontName.isEmpty {
                return .custom(fontName, size: fontSize)
            }
        }

        // 3. 保底：系统字体
        return .system(size: fontSize)
    }

    /// 通过 JavaScriptCore 执行壁纸脚本，用当前时间生成正确文本
    /// 每个唯一脚本只 eval 一次，之后只调用 update() 获取最新时间
    private static var jsContextCache: [String: JSContext] = [:]
    private static func executeWallpaperScript(_ script: String, scriptPropertiesJSON: String?) -> String? {
        // 用脚本 + renderer 实际属性做 key；同一脚本在不同语言/格式属性下必须独立缓存。
        let ctxCacheKey = script + "\n__scriptProperties=" + (scriptPropertiesJSON ?? "{}")

        let ctx: JSContext
        if let cached = jsContextCache[ctxCacheKey] {
            ctx = cached
        } else {
            ctx = JSContext()
            ctx.exceptionHandler = { _, exception in
                print("[JSError] \(exception?.toString() ?? "unknown")")
            }
            // createScriptProperties 和脚本合并到一次 eval 中
            // 注意：必须智能处理各种 export 语法
            let cleanedScript = Self.cleanScriptForJSContext(script)
            // 注入 Wallpaper Engine 脚本属性桥接；语言数组由壁纸脚本自己声明。
            let bundled = """
            var createScriptProperties = function() {
                var props = {};
                var overrideProps = \(Self.normalizedScriptPropertiesJSON(scriptPropertiesJSON) ?? "{}");
                return new Proxy({}, {
                    get: function(target, name) {
                        if (name === 'finish') return function() { return props; };
                        return function(c) {
                            if (c && c.name !== undefined) {
                                props[c.name] = Object.prototype.hasOwnProperty.call(overrideProps, c.name) ? overrideProps[c.name] : c.value;
                            }
                            return this;
                        };
                    }
                });
            };
            \(cleanedScript)
            """
            ctx.exception = nil
            ctx.evaluateScript(bundled)
            if ctx.exception != nil {
                print("[JSError] Failed to evaluate script")
                return nil
            }
            jsContextCache[ctxCacheKey] = ctx
        }

        // 每次调用 update() 获取当前时间
        guard let updateFn = ctx.objectForKeyedSubscript("update"), !updateFn.isUndefined else {
            return nil
        }
        ctx.exception = nil
        // 传 0 而非空字符串，避免 update(dt) 中 dt.toFixed() 等操作产生 NaN
        let result = updateFn.call(withArguments: [0])
        // 运行时错误（如缺失外部全局变量）不打印，静默回退到 formatter
        ctx.exception = nil
        guard let text = result?.toString(), !text.isEmpty, text != "undefined" else {
            return nil
        }
        return text
    }

    /// 清除脚本中的 ES module export 语法，使其能在 JSContext（无模块系统）中正常运行。
    /// 处理模式：
    ///   `export function name()` → `function name()`
    ///   `export { foo, bar }`   → 移除该行（符号已全局定义）
    ///   `export default X`      → 移除 export default，保留 X
    ///   `export default { }`    → `{ }`（有效表达式）
    private static func cleanScriptForJSContext(_ script: String) -> String {
        script.components(separatedBy: .newlines).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("export ") else { return line }

            let afterExport = String(trimmed.dropFirst(7))
            if afterExport.hasPrefix("default ") {
                // export default function() {} → function() {}（匿名函数声明无效，需要特殊处理）
                // export default { ... } → { ... }（有效）
                // export default expression → 直接保留 expression
                return line.replacingOccurrences(of: "export default ", with: "")
            } else if afterExport.hasPrefix("{") || afterExport == "{" {
                // export { update } → 移除整行，函数定义已存在全局作用域
                return "" // 仅注释掉
            } else if afterExport.hasPrefix("function ") || afterExport.hasPrefix("class ") {
                // export function / export class → 保留定义
                return line.replacingOccurrences(of: "export ", with: "")
            } else if afterExport.hasPrefix("const ") || afterExport.hasPrefix("let ") || afterExport.hasPrefix("var ") {
                // export const/let/var → 保留声明
                return line.replacingOccurrences(of: "export ", with: "")
            } else {
                // export * from / export type 等 → 移除
                return ""
            }
        }.joined(separator: "\n")
    }

    private static func normalizedScriptPropertiesJSON(_ json: String?) -> String? {
        guard let json,
              let data = json.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data),
              let normalized = normalizeScriptPropertyValue(decoded),
              JSONSerialization.isValidJSONObject(normalized),
              let encoded = try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]),
              let output = String(data: encoded, encoding: .utf8)
        else {
            return json
        }
        return output
    }

    private static func normalizeScriptPropertyValue(_ value: Any) -> Any? {
        if let dict = value as? [String: Any] {
            if dict.keys.contains("value") {
                guard let rawValue = dict["value"] else { return nil }
                return normalizeScriptPropertyValue(rawValue)
            }
            var output: [String: Any] = [:]
            for (key, rawValue) in dict {
                output[key] = normalizeScriptPropertyValue(rawValue) ?? rawValue
            }
            return output
        }
        if let array = value as? [Any] {
            return array.map { normalizeScriptPropertyValue($0) ?? $0 }
        }
        return value
    }

    /// 注册字体并返回 PostScript 名称
    private static var psCache = [String: String]()
    private static func registeredPSName(path: String) -> String? {
        if let cached = psCache[path] { return cached }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider),
              let psName = cgFont.postScriptName as String? else { return nil }

        CTFontManagerRegisterGraphicsFont(cgFont, nil)
        psCache[path] = psName
        return psName
    }

    private var color: Color {
        let values = entry.color ?? [1, 1, 1]
        let red = values.indices.contains(0) ? values[0] : 1
        let green = values.indices.contains(1) ? values[1] : 1
        let blue = values.indices.contains(2) ? values[2] : 1
        return Color(red: red, green: green, blue: blue)
    }

    private var textAlignment: TextAlignment {
        let alignment = entry.alignment?.lowercased() ?? ""
        if alignment.contains("left") { return .leading }
        if alignment.contains("right") { return .trailing }
        return .center
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// 英文日期/星期 formatter（默认）
    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    /// 中文日期/星期 formatter（仅当壁纸条目名含中文时使用）
    private static let chineseWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh-CN")
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let chineseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh-CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// 条目名称是否包含中文字符
    private static func isChineseName(_ name: String) -> Bool {
        name.unicodeScalars.contains(where: { $0.properties.isIdeographic })
    }
}
