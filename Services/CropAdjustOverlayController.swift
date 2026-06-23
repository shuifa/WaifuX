import AppKit
import CoreGraphics

/// 桌面可视区域调节 overlay：每屏一个全屏窗口，拖拽平移、滚轮缩放、ESC 退出。
/// overlay 自带预览渲染，不依赖实际壁纸层；退出时 settings 已持久化，渲染器按持久化值刷新。
@MainActor
final class CropAdjustOverlayController {
    static let shared = CropAdjustOverlayController()

    private var windowsByScreenID: [String: NSWindow] = [:]
    private weak var statusItem: NSStatusItem?

    private init() {}

    // MARK: - Public

    func isActive(for screen: NSScreen) -> Bool {
        windowsByScreenID[screen.wallpaperScreenIdentifier] != nil
    }

    func toggle(for screen: NSScreen, statusBarItemRef: NSStatusItem?) {
        self.statusItem = statusBarItemRef
        if isActive(for: screen) {
            exit(for: screen)
        } else {
            enter(for: screen)
        }
    }

    // MARK: - Enter / Exit

    private func enter(for screen: NSScreen) {
        let screenID = screen.wallpaperScreenIdentifier
        guard windowsByScreenID[screenID] == nil else { return }

        let window = CropAdjustOverlayWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen)
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let view = CropAdjustOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen)
        view.onSettingsChanged = { [weak self] in
            // 触发菜单刷新（更新比例打勾等）
            self?.statusItem?.button?.needsDisplay = true
        }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        windowsByScreenID[screenID] = window
    }

    private func exit(for screen: NSScreen) {
        let screenID = screen.wallpaperScreenIdentifier
        // 退出调节：落定一次确保 Darwin 已广播 / wgpu 已按最终 crop 重启
        DisplayCropSettingsStore.shared.commitInteractive(for: screen)
        if let window = windowsByScreenID.removeValue(forKey: screenID) {
            window.orderOut(nil)
        }
    }
}

/// overlay 窗口：ESC 退出。
private final class CropAdjustOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            CropAdjustOverlayController.shared.toggle(
                for: self.screen ?? NSScreen.main!, statusBarItemRef: nil)
            return
        }
        super.keyDown(with: event)
    }
}

/// overlay 视图：预览 + 拖拽/滚轮手势。
private final class CropAdjustOverlayView: NSView {
    private let screen: NSScreen
    private var lastDragLocation: NSPoint?
    var onSettingsChanged: (() -> Void)?

    init(frame: NSRect, screen: NSScreen) {
        self.screen = screen
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
        renderPreview()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 预览渲染

    /// 只画辅助 UI（可视框虚线边框 + 框外半透明暗化 + 提示文字），不遮挡真实壁纸。
    /// 拖拽时 store 更新 → cropDidChangeNotification → 各渲染器实时刷新，用户透过 overlay 看到实际效果。
    private func renderPreview() {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }

        let settings = DisplayCropSettingsStore.shared.settings(for: screen)
        let layout = CropLayoutEngine.compute(
            wallpaperSize: screen.frame.size,
            screenSize: screen.frame.size,
            settings: settings)

        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        // 可视框像素矩形
        let vp = CGRect(
            x: layout.viewportRect.x * bounds.width,
            y: (1.0 - layout.viewportRect.y - layout.viewportRect.h) * bounds.height,
            width: layout.viewportRect.w * bounds.width,
            height: layout.viewportRect.h * bounds.height)

        // 框外暗化：全屏半透明填充 + viewport 区域挖空，叠加在真实壁纸上。
        // 使用 CGPath 的 evenOdd 填充规则：outer rect + inner rect = 框外着色。
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        dimPath.addRect(vp)
        let dimLayer = CAShapeLayer()
        dimLayer.path = dimPath
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor(white: 0, alpha: 0.25).cgColor
        layer?.addSublayer(dimLayer)

        // 可视框虚线边框
        let border = CAShapeLayer()
        border.path = CGPath(rect: vp, transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.systemYellow.cgColor
        border.lineWidth = 2
        border.lineDashPattern = [6, 4]
        layer?.addSublayer(border)

        // 提示文字
        let text = CATextLayer()
        text.string = "拖动平移 · 滚轮缩放 · ESC 退出"
        text.foregroundColor = NSColor.white.cgColor
        text.fontSize = 16
        text.alignmentMode = .center
        text.frame = CGRect(x: 0, y: bounds.midY - 40, width: bounds.width, height: 24)
        text.contentsScale = window?.screen?.backingScaleFactor ?? 2
        // 文字加阴影以便在亮色壁纸上可见
        text.shadowColor = NSColor.black.cgColor
        text.shadowOpacity = 0.8
        text.shadowOffset = CGSize(width: 0, height: -1)
        text.shadowRadius = 3
        layer?.addSublayer(text)
    }

    // MARK: - 手势
    // 约定：pan 正值 = 画面看向该方向（见 DisplayCropSettings.pan 文档）。
    // 拖拽采用「画面跟手」隐喻：拖右 → 画面右移 → pan.x 增大；拖上 → 画面上移 → pan.y 减小。
    // 注意 NSEvent.mouseLocation 是屏幕坐标 y 向上为正，而 pan.y 是图像 y 向下为正，故需取反。

    override func mouseDown(with event: NSEvent) {
        lastDragLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDragLocation else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - last.x
        let dy = current.y - last.y
        lastDragLocation = current

        // 灵敏度：拖动 1/4 屏宽度对应 pan 变化 1（比 1/2 屏更跟手）
        let sensitivity = max(1, bounds.width / 4)
        // interactive=true：只本进程内即时刷新 + 写 App Group JSON，不广播 Darwin、不重启 wgpu
        DisplayCropSettingsStore.shared.update(for: screen, interactive: true) { s in
            s.pan.x = max(-1, min(1, s.pan.x + dx / sensitivity))
            s.pan.y = max(-1, min(1, s.pan.y - dy / sensitivity))
        }
        renderPreview()
        onSettingsChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        lastDragLocation = nil
        // 拖拽结束：落定一次（持久化 + 广播 Darwin + 重启 wgpu）
        DisplayCropSettingsStore.shared.commitInteractive(for: screen)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.deltaY
        guard delta != 0 else { return }
        // 滚轮也是 interactive，避免每个 tick 重启 wgpu
        DisplayCropSettingsStore.shared.update(for: screen, interactive: true) { s in
            s.zoom = max(1.0, min(4.0, s.zoom * (1 + delta * 0.03)))
        }
        renderPreview()
        onSettingsChanged?()
        // 滚轮通常无明确"释放"事件，用 phase=.ended 判断；否则用 debounce
        if event.phase == .ended || event.momentumPhase == .ended {
            DisplayCropSettingsStore.shared.commitInteractive(for: screen)
        } else {
            scheduleScrollCommit()
        }
    }

    private var scrollCommitWorkItem: DispatchWorkItem?
    private func scheduleScrollCommit() {
        scrollCommitWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            DisplayCropSettingsStore.shared.commitInteractive(for: self.screen)
        }
        scrollCommitWorkItem = item
        // 滚动停止 250ms 后落定
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
}
