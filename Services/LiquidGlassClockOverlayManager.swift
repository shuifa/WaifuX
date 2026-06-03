import AppKit
import SwiftUI
import Combine
import MetalKit
import CoreText

// MARK: - 液态玻璃时钟 Overlay 管理器
//
// 为每个屏幕创建透明 NSWindow，在桌面壁纸层之上渲染
// LiquidGlassClockView。配合烘焙场景壁纸使用。
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

        // 监听视频壁纸激活状态变化 → 自动显示/隐藏时钟
        VideoWallpaperManager.shared.$currentVideoURL
            .receive(on: DispatchQueue.main)
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

    /// 立即刷新所有屏幕的时钟窗口（外部调用，如热键切换）
    public func refreshAll() {
        let config = LiquidGlassClockSettings.shared.config
        applyConfig(config)
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
        return WallpaperDynamicTextParser.loadSidecar(for: videoURL)
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
        // 总开关：如果用户关闭了桌面动态元素，任何情况都不显示
        guard config.enabled else { return false }
        // 有视频壁纸时，检查 sidecar 动态文本补偿层
        if VideoWallpaperManager.shared.isVideoWallpaperActive,
           let videoURL = VideoWallpaperManager.shared.currentVideoURL {
            return WallpaperDynamicTextParser.hasDynamicText(for: videoURL)
        }
        // 无视频壁纸时显示纯桌面时钟
        return true
    }

    // MARK: - 定时器管理

    /// 启动每秒定时器（驱动 MTKView 重绘 + SwiftUI 时钟更新）
    private func startClockTimer() {
        guard clockTickTimer == nil else { return }
        clockTickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.currentConfig.enabled else { return }

            if self.currentConfig.metalShaderEnabled {
                // Metal 路径：手动触发重绘（shouldRedraw 内部会跳过无效帧）
                for (_, mtkView) in self.metalViews {
                    LiquidGlassMetalRenderer.shared.requestRedraw(view: mtkView)
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

    /// 构建适配指定屏幕的时钟视图（含位置计算）
    private func makeClockView(for screen: NSScreen, config: LiquidGlassClockConfiguration, screenID: String = "") -> some View {
        let sidecarInfo = currentDynamicTextInfo()
        let rendererEntries = sidecarInfo?.entries.filter { entry in
            entry.visible && (
                entry.finalOriginX != nil || entry.originX != nil || entry.finalX != nil ||
                entry.finalOriginY != nil || entry.originY != nil || entry.finalY != nil
            )
        } ?? []
        if !rendererEntries.isEmpty {
            return AnyView(
                RendererDynamicTextOverlayView(
                    entries: rendererEntries,
                    sceneWidth: sidecarInfo?.sceneWidth,
                    sceneHeight: sidecarInfo?.sceneHeight,
                    screenSize: screen.frame.size
                )
            )
        }

        let alignment: Alignment
        let edgePadding: EdgeInsets

        switch config.corner {
        case .topLeft:
            alignment = .topLeading
            edgePadding = EdgeInsets(top: config.verticalPadding, leading: config.horizontalPadding, bottom: 0, trailing: 0)
        case .topRight:
            alignment = .topTrailing
            edgePadding = EdgeInsets(top: config.verticalPadding, leading: 0, bottom: 0, trailing: config.horizontalPadding)
        case .bottomLeft:
            alignment = .bottomLeading
            edgePadding = EdgeInsets(top: 0, leading: config.horizontalPadding, bottom: config.verticalPadding, trailing: 0)
        case .bottomRight:
            alignment = .bottomTrailing
            edgePadding = EdgeInsets(top: 0, leading: 0, bottom: config.verticalPadding, trailing: config.horizontalPadding)
        }

        // 如果启用 Metal 路径，注册 MTKView 以便暂停/恢复
        let sid = screenID

        return AnyView(ZStack {
            Color.clear
                .ignoresSafeArea()

            LiquidGlassClockView(config: config, mtkViewRegistry: { [weak self] mtkView in
                guard let self = self else { return }
                if !sid.isEmpty {
                    self.metalViews[sid] = mtkView
                    if VideoWallpaperManager.shared.isPaused {
                        mtkView.isPaused = true
                    }
                }
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(edgePadding)
        })
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

private struct RendererDynamicTextOverlayView: View {
    let entries: [DynamicTextEntry]
    let sceneWidth: Double?
    let sceneHeight: Double?
    let screenSize: CGSize

    @State private var now = Date()

    private let timer = Timer.publish(every: 1, tolerance: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.ignoresSafeArea()
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                RendererDynamicTextView(entry: entry, now: now)
                    .position(position(for: entry))
                    .zIndex(Double(entry.renderOrder ?? 0))
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .onReceive(timer) { now = $0 }
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

        let x = rawX / max(sourceWidth, 1) * Double(screenSize.width)
        let y = (1 - rawY / max(sourceHeight, 1)) * Double(screenSize.height)
        return CGPoint(x: x, y: y)
    }
}

private struct RendererDynamicTextView: View {
    let entry: DynamicTextEntry
    let now: Date

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
        switch entry.behavior {
        case "clock":
            return Self.clockFormatter.string(from: now)
        case "weekday":
            let raw = Self.weekdayFormatter.string(from: now).uppercased()
            // C++ renderer 对 Day 对象会加空格: "W E D N E S D A Y"
            let name = entry.name.lowercased().replacingOccurrences(of: " ", with: "")
            if name == "day" || name.contains("day") {
                return raw.map { String($0) }.joined(separator: "  ")
            }
            return raw
        case "date":
            return Self.dateFormatter.string(from: now)
        default:
            return entry.value ?? ""
        }
    }

    /// 字体：注册后用 Font.custom(psName, size:) 加载，失败用 system font
    /// effectiveFontSize 是 C++ 渲染器在 3840×2160 场景下的像素值，
    /// 加 15% 补偿屏幕比例差异。
    private var font: Font {
        let ptSize = CGFloat(entry.effectiveFontSize ?? entry.fontSize ?? 32) * 1.15

        if let path = entry.fontPath, !path.isEmpty,
           let psName = Self.registeredPSName(path: path) {
            return .custom(psName, size: ptSize)
        }

        return .system(size: ptSize)
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

    /// 加载字体、注册、返回 PostScript 名称供 Font.custom 使用。
    /// 先把字体写入临时文件，再用 CTFontManagerRegisterFontsForURL 注册，
    /// 这是 macOS 上最标准的字体注册方式，能正确解析 cmap/OS2 等字体表。
    private static var registeredPSNames = [String: String]()
    private static func registeredCTFont(from path: String, size: CGFloat) -> CTFont? {
        // 已有缓存 → 用缓存名称创建 CTFont
        if let psName = registeredPSNames[path] {
            return CTFontCreateWithName(psName as CFString, size, nil)
        }

        guard let fontData = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }

        // 写入临时文件再注册（CTFontManagerRegisterFontsForURL 是 macOS 最标准的 API）
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("otf")
        do { try fontData.write(to: tempURL) } catch { return nil }

        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(tempURL as CFURL, .process, &error)

        // 获取 PostScript 名
        guard let descArray = CTFontManagerCreateFontDescriptorsFromURL(tempURL as CFURL),
              let descriptors = descArray as? [CTFontDescriptor],
              let descriptor = descriptors.first else { return nil }

        let ctFont = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        let psName = CTFontCopyPostScriptName(ctFont) as String? ?? ""
        guard !psName.lowercased().hasPrefix("helvetica") else { return nil }

        registeredPSNames[path] = psName
        // 同时也用 RegisterGraphicsFont 注册（保险）
        if let provider = CGDataProvider(data: fontData as CFData),
           let cgFont = CGFont(provider) {
            CTFontManagerRegisterGraphicsFont(cgFont, nil)
        }
        return ctFont
    }
}
