import AppKit
import Combine

/// 静态壁纸独立显示 Overlay 管理器
///
/// 当「系统壁纸同步」关闭时，静态壁纸不再走 `setDesktopImageURL`，
/// 改由本管理器在 desktop 级 NSWindow 上用 NSImageView 直接覆盖桌面显示，
/// 与视频/场景/web 动态壁纸引擎各自独立、互不干扰。
///
/// 窗口层级与 `VideoWallpaperManager` 的视频壁纸窗口一致（`CGWindowLevelForKey(.desktopWindow)`），
/// 低于颗粒蒙层（`+1`）与时钟 overlay（`+20`），叠加顺序天然正确。
///
/// 持久化：每屏静态图 URL 写入 UserDefaults（`static_image_overlay_state_v1`），
/// App 启动时 `restoreIfNeeded()` 在 sync 关闭且无活跃动态壁纸时自动重建 overlay。
@MainActor
final class StaticImageWallpaperOverlayManager {
    static let shared = StaticImageWallpaperOverlayManager()

    /// 每个屏幕的静态图 overlay 窗口（key 为 screenID）
    private var imageWindows: [String: NSWindow] = [:]

    /// 每个屏幕当前显示的图片 URL（内存镜像，供 refreshWindows 重建使用）
    private var imageByScreen: [String: URL] = [:]

    private var cancellables = Set<AnyCancellable>()

    /// 持久化键：`{screenID: imageURLString}` JSON
    private static let stateKey = "static_image_overlay_state_v1"

    private init() {
        // Space 切换后重新显示 overlay（desktop 级窗口可能被系统重排）
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        // 屏幕配置变化（外接显示器插拔）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // 系统唤醒后刷新
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    // MARK: - 显示 / 隐藏

    /// 为所有屏幕显示同一张静态图，并持久化状态。
    func showAll(imageURL: URL) {
        for screen in NSScreen.screens {
            show(imageURL: imageURL, for: screen)
        }
        persistState()
    }

    /// 为指定屏幕显示静态图（覆盖已有窗口），并持久化状态。
    func show(imageURL: URL, for screen: NSScreen) {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            print("[StaticImageOverlay] ⚠️ 图片不存在，跳过 overlay 显示: \(imageURL.path)")
            return
        }
        let screenID = screen.wallpaperScreenIdentifier
        imageByScreen[screenID] = imageURL

        if let existing = imageWindows[screenID] {
            // 复用窗口，只更新图片
            updateContentView(of: existing, imageURL: imageURL, size: screen.frame.size)
            existing.orderFront(nil)
        } else {
            createWindow(for: screen, imageURL: imageURL)
        }
        persistState()
    }

    /// 隐藏指定屏幕的 overlay（保留持久化记录，供下次 restoreIfNeeded 恢复）。
    func hide(for screen: NSScreen) {
        let screenID = screen.wallpaperScreenIdentifier
        if let window = imageWindows.removeValue(forKey: screenID) {
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    /// 隐藏所有屏幕的 overlay（保留持久化记录）。
    func hideAll() {
        for (_, window) in imageWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        imageWindows.removeAll()
    }

    /// 彻底清除持久化状态（切到视频/场景/web 或系统壁纸时调用）。
    func clearState() {
        imageByScreen.removeAll()
        hideAll()
        UserDefaults.standard.removeObject(forKey: Self.stateKey)
    }

    // MARK: - 启动恢复

    /// App 启动时调用：系统壁纸同步关闭且无活跃动态壁纸时，从持久化状态重建 overlay。
    func restoreIfNeeded() {
        // 系统壁纸同步开启 → 走系统壁纸，不需要 overlay
        guard !VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled else {
            return
        }
        // 有活跃视频壁纸 → 视频窗口已覆盖桌面，不需要静态 overlay
        if VideoWallpaperManager.shared.isVideoWallpaperActive {
            return
        }
        // 有持久化的场景/web 壁纸待恢复（启动竞态防护）：
        // WaifuXApp 里 WE restore 是 async Task，restoreIfNeeded() 同步执行时
        // isControllingExternalEngine 可能仍为 false。用 hasPersistedRestoreState()
        // 同步预测 WE 将被恢复，避免静态 overlay 先弹出再被 WE 窗口盖住。
        if WallpaperEngineXBridge.shared.hasPersistedRestoreState() {
            return
        }
        // 有活跃场景/web 壁纸 → renderer 窗口已覆盖桌面，不需要静态 overlay
        if WallpaperEngineXBridge.shared.isControllingExternalEngine {
            return
        }

        guard let saved = loadState(), !saved.isEmpty else {
            return
        }

        // 按当前屏幕匹配已保存的图片 URL；匹配不到（屏幕已拔）的记录跳过。
        let currentScreens = NSScreen.screens
        var restored = 0
        for screen in currentScreens {
            let screenID = screen.wallpaperScreenIdentifier
            guard let urlString = saved[screenID], let url = URL(string: urlString) else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            show(imageURL: url, for: screen)
            restored += 1
        }
        if restored > 0 {
            print("[StaticImageOverlay] ✅ 启动恢复 \(restored) 屏静态图 overlay")
        }
    }

    // MARK: - 窗口创建

    private func createWindow(for screen: NSScreen, imageURL: URL) {
        let screenID = screen.wallpaperScreenIdentifier
        let frame = screen.frame

        let window = StaticImageOverlayWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.setFrame(frame, display: true)
        // 与 VideoWallpaperManager 视频壁纸窗口一致：精确 desktop 级
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.animationBehavior = .none

        updateContentView(of: window, imageURL: imageURL, size: frame.size)

        imageWindows[screenID] = window
        window.orderFront(nil)
    }

    /// 设置/更新窗口内容视图为指定图片（Aspect Fill 填满）。
    private func updateContentView(of window: NSWindow, imageURL: URL, size: NSSize) {
        let imageView = NSImageView(frame: CGRect(origin: .zero, size: size))
        imageView.imageScaling = .scaleAxesIndependently  // 拉伸填满整个窗口（Aspect Fill 语义）
        imageView.image = NSImage(contentsOf: imageURL)
        window.contentView = imageView
    }

    // MARK: - 刷新（屏幕插拔）

    func refreshWindows() {
        let currentScreenIDs = Set(NSScreen.screens.map { $0.wallpaperScreenIdentifier })
        // 移除已断开屏幕的窗口
        for (screenID, window) in imageWindows {
            if !currentScreenIDs.contains(screenID) {
                window.orderOut(nil)
                window.contentView = nil
                imageWindows.removeValue(forKey: screenID)
            }
        }
        // 同步现有窗口帧 + 重建缺失窗口
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            if let window = imageWindows[screenID] {
                window.setFrame(screen.frame, display: true)
                window.contentView?.frame = CGRect(origin: .zero, size: screen.frame.size)
            } else if let imageURL = imageByScreen[screenID] {
                // 屏幕重连且本管理器记录过该屏图片 → 重建
                createWindow(for: screen, imageURL: imageURL)
            }
        }
    }

    // MARK: - 持久化

    private func persistState() {
        let dict = imageByScreen.mapValues { $0.absoluteString }
        if dict.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.stateKey)
        } else if let data = try? JSONSerialization.data(withJSONObject: dict),
                  let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: Self.stateKey)
        }
    }

    private func loadState() -> [String: String]? {
        guard let str = UserDefaults.standard.string(forKey: Self.stateKey),
              let data = str.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return dict
    }

    // MARK: - 通知

    @objc private func handleSpaceChanged() {
        // Space 切换后延迟重新显示，确保窗口层级正确
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            for (screenID, window) in self.imageWindows {
                if self.imageByScreen[screenID] != nil {
                    window.orderFront(nil)
                }
            }
        }
    }

    @objc private func handleScreenParametersChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshWindows()
        }
    }

    @objc private func handleWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshWindows()
        }
    }
}

// MARK: - 窗口子类

/// 静态图 overlay 窗口：不可成为 key/main，避免抢焦点（对齐 WallpaperVideoWindow）。
private final class StaticImageOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
