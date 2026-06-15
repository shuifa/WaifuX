import AppKit
import Combine

// MARK: - 菜单栏音量滑块自定义视图
private final class WallpaperVolumeSliderView: NSView {
    private let iconView = NSImageView()
    private let slider = NSSlider()
    private var cancellables = Set<AnyCancellable>()

    var onVolumeChanged: ((Double) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        // 图标
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // 滑块
        slider.minValue = 0
        slider.maxValue = 100
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            slider.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let value = Double(sender.doubleValue) / 100.0
        onVolumeChanged?(value)
        updateIcon(volume: value)
    }

    func setVolume(_ volume: Double, isMuted: Bool) {
        let effectiveVolume = isMuted ? 0 : volume
        slider.doubleValue = effectiveVolume * 100
        updateIcon(volume: effectiveVolume)
    }

    private func updateIcon(volume: Double) {
        let name: String
        if volume == 0 {
            name = "speaker.slash.fill"
        } else if volume < 0.35 {
            name = "speaker.wave.1.fill"
        } else if volume < 0.7 {
            name = "speaker.wave.2.fill"
        } else {
            name = "speaker.wave.3.fill"
        }
        iconView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}

// MARK: - 单屏幕音量控制（名称 + 滑块）
private final class ScreenVolumeControlView: NSView {
    private let nameLabel = NSTextField()
    private let sliderView = WallpaperVolumeSliderView()

    var onVolumeChanged: ((Double) -> Void)? {
        didSet { sliderView.onVolumeChanged = onVolumeChanged }
    }

    init(screenName: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
        setupUI(screenName: screenName)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI(screenName: String) {
        nameLabel.stringValue = screenName
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.backgroundColor = .clear
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        sliderView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(nameLabel)
        addSubview(sliderView)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            sliderView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            sliderView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            sliderView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            sliderView.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    func setVolume(_ volume: Double, isMuted: Bool) {
        sliderView.setVolume(volume, isMuted: isMuted)
    }
}

@MainActor
final class StatusBarController: NSObject {
    // MARK: - 单例
    static let shared = StatusBarController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private lazy var openWindowItem = NSMenuItem(title: t("statusbar.showWindow"), action: #selector(showMainWindow), keyEquivalent: "")
    private lazy var openLibraryItem = NSMenuItem(title: t("statusbar.openMyLibrary"), action: #selector(openMyLibrary), keyEquivalent: "")
    private lazy var releaseMemoryItem = NSMenuItem(title: t("statusbar.releaseMemory"), action: #selector(releaseForegroundMemory), keyEquivalent: "")
    private lazy var toggleWallpaperItem = NSMenuItem(title: t("statusbar.enableWallpaper"), action: #selector(toggleDynamicWallpaper), keyEquivalent: "")
    private lazy var playPauseItem = NSMenuItem(title: t("statusbar.pauseWallpaper"), action: #selector(togglePlayback), keyEquivalent: "")
    private lazy var muteItem = NSMenuItem(title: t("statusbar.muteWallpaper"), action: #selector(toggleMute), keyEquivalent: "")
    private lazy var desktopIconsItem = NSMenuItem(title: t("statusbar.hideDesktopIcons"), action: #selector(toggleDesktopIcons), keyEquivalent: "")
    private lazy var designWallpaperItem = NSMenuItem(title: "设计壁纸", action: #selector(openWebWallpaperDesignPanel), keyEquivalent: "")
    private lazy var quitItem = NSMenuItem(title: t("statusbar.quit"), action: #selector(quitApplication), keyEquivalent: "q")

    private let videoWallpaperManager = VideoWallpaperManager.shared
    private let weBridge = WallpaperEngineXBridge.shared
    private var showWindowHandler: (() -> Void)?
    private var releaseMemoryHandler: (() -> Void)?
    private var quitHandler: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()

    // 各屏幕独立音量条
    private var screenVolumeItems: [NSMenuItem] = []
    // 各屏幕独立暂停/关闭菜单项
    private var wallpaperControlItems: [NSMenuItem] = []

    // 标记是否已配置，防止重复配置
    private var isConfigured = false

    private override init() {
        super.init()
        configureStatusItem()
        bindWallpaperState()
        refreshMenuState()
    }

    /// 配置处理程序（只能调用一次）
    func configure(showWindow: @escaping () -> Void, releaseMemory: @escaping () -> Void, quit: @escaping () -> Void) {
        guard !isConfigured else {
            print("[StatusBarController] Already configured, skipping...")
            return
        }
        self.showWindowHandler = showWindow
        self.releaseMemoryHandler = releaseMemory
        self.quitHandler = quit
        self.isConfigured = true
    }

    private func configureStatusItem() {
        // 确保状态栏项的按钮存在
        guard let button = statusItem.button else {
            print("[StatusBarController] Failed to get status item button")
            return
        }

        // 尝试使用系统图标，如果不存在则使用备用图标
        let systemImageNames = ["sparkles.tv", "photo.fill", "tv.fill", "desktopcomputer"]
        var image: NSImage?

        for name in systemImageNames {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "WaifuX") {
                image = img
                break
            }
        }

        if let image = image {
            image.isTemplate = true
            // 在 macOS 14 上需要设置合适的图标大小
            image.size = NSSize(width: 18, height: 18)
            button.image = image
        } else {
            // 最后的备选方案：使用文字
            button.title = "WH"
            button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        }

        button.toolTip = "WaifuX"

        openWindowItem.target = self
        openLibraryItem.target = self
        releaseMemoryItem.target = self
        muteItem.target = self
        desktopIconsItem.target = self
        designWallpaperItem.target = self
        quitItem.target = self

        menu.addItem(openWindowItem)
        menu.addItem(openLibraryItem)
        menu.addItem(releaseMemoryItem)
        menu.addItem(.separator())
        menu.addItem(desktopIconsItem)
        menu.addItem(designWallpaperItem)
        // toggleWallpaperItem 和 playPauseItem 在 refreshMenuState 中动态构建
        menu.addItem(muteItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
        menu.delegate = self
    }

    private func bindWallpaperState() {
        videoWallpaperManager.$currentVideoURL
            .combineLatest(videoWallpaperManager.$isPaused, videoWallpaperManager.$isMuted, videoWallpaperManager.$volume)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in
                self?.refreshMenuState()
            }
            .store(in: &cancellables)

        weBridge.$isControllingExternalEngine
            .combineLatest(weBridge.$isExternalPaused)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.refreshMenuState()
            }
            .store(in: &cancellables)
    }

    /// 为指定屏幕构建音量滑块菜单项
    private func buildVolumeMenuItem(for screen: NSScreen) -> NSMenuItem {
        let controlView = ScreenVolumeControlView(screenName: screen.localizedName)
        controlView.onVolumeChanged = { [weak self] volume in
            guard let self = self else { return }
            // 只设该屏幕的音量，不触及其他屏幕，也不动全局静音
            self.videoWallpaperManager.setVolume(volume, for: screen)
            if self.weBridge.isControllingExternalEngine {
                self.weBridge.setVolume(volume, for: screen)
            }
        }
        let item = NSMenuItem()
        item.view = controlView
        let vol = videoWallpaperManager.volume(for: screen)
        // 显示实际音量，不受全局 isMuted 影响
        controlView.setVolume(vol, isMuted: false)
        return item
    }

    private func refreshMenuState() {
        let hasNativeWallpaper = videoWallpaperManager.isVideoWallpaperActive
        let hasExternalWallpaper = weBridge.isControllingExternalEngine
        let hasWallpaper = hasNativeWallpaper || hasExternalWallpaper
        let shouldShowDesignWallpaperItem: Bool
        if let sceneWallpaperPath = currentSceneDesignWallpaperPath() {
            shouldShowDesignWallpaperItem = true
            designWallpaperItem.representedObject = sceneWallpaperPath
        } else if let wallpaperPath = weBridge.currentWallpaperPathForDesign {
            if weBridge.isCurrentWallpaperWeb {
                shouldShowDesignWallpaperItem = WebWallpaperDesignService.shared.hasEditableProperties(for: wallpaperPath)
                designWallpaperItem.representedObject = wallpaperPath
            } else if weBridge.isCurrentWallpaperScene {
                shouldShowDesignWallpaperItem = true
                designWallpaperItem.representedObject = wallpaperPath
            } else {
                shouldShowDesignWallpaperItem = false
                designWallpaperItem.representedObject = nil
            }
        } else {
            shouldShowDesignWallpaperItem = false
            designWallpaperItem.representedObject = nil
        }
        designWallpaperItem.isHidden = !shouldShowDesignWallpaperItem
        designWallpaperItem.isEnabled = shouldShowDesignWallpaperItem

        // 移除旧的动态菜单项
        for item in wallpaperControlItems {
            if item.menu != nil {
                menu.removeItem(item)
            }
        }
        wallpaperControlItems.removeAll()

        // 构建各屏幕独立的暂停/关闭/音量菜单项
        let activeScreens = videoWallpaperManager.activeScreens

        // macOS 26+：扩展控制模式下，activeScreens 为空但壁纸仍活跃
        // 使用所有屏幕 + per-display prefs 来构建控件
        let isExtensionMode: Bool
        if #available(macOS 26.0, *), videoWallpaperManager.isLockScreenMirroringActive {
            isExtensionMode = true
        } else {
            isExtensionMode = false
        }

        let screensToShow: [NSScreen]
        if isExtensionMode {
            screensToShow = NSScreen.screens
        } else if hasExternalWallpaper {
            let nativeScreenIDs = Set(activeScreens.map(\.wallpaperScreenIdentifier))
            screensToShow = NSScreen.screens.filter { screen in
                nativeScreenIDs.contains(screen.wallpaperScreenIdentifier) || weBridge.isManaging(screen: screen)
            }
        } else {
            screensToShow = activeScreens
        }

        let isMultiScreenNative = screensToShow.count > 1

        if isMultiScreenNative {
            for screen in screensToShow {
                let screenName = screen.localizedName

                // 获取暂停状态：扩展模式用 prefs，本地模式用 player
                let isScreenPaused: Bool
                if isExtensionMode, #available(macOS 26.0, *),
                   let displayID = Self.cgDisplayID(for: screen) {
                    isScreenPaused = LockScreenWallpaperService.shared.isDisplayPaused(displayID)
                } else if weBridge.isManaging(screen: screen) {
                    isScreenPaused = weBridge.isExternalPaused
                } else {
                    isScreenPaused = videoWallpaperManager.isPaused(on: screen)
                }

                let pauseItem = NSMenuItem(
                    title: isScreenPaused
                        ? "\(t("statusbar.resumeWallpaper")) (\(screenName))"
                        : "\(t("statusbar.pauseWallpaper")) (\(screenName))",
                    action: #selector(perScreenTogglePlayback(_:)),
                    keyEquivalent: ""
                )
                pauseItem.target = self
                pauseItem.representedObject = screen
                wallpaperControlItems.append(pauseItem)

                let disableItem = NSMenuItem(
                    title: "\(t("statusbar.disableWallpaper")) (\(screenName))",
                    action: #selector(perScreenToggleDynamicWallpaper(_:)),
                    keyEquivalent: ""
                )
                disableItem.target = self
                disableItem.representedObject = screen
                wallpaperControlItems.append(disableItem)

                if !isExtensionMode {
                    wallpaperControlItems.append(buildVolumeMenuItem(for: screen))
                }
            }
        } else {
            toggleWallpaperItem.title = hasWallpaper ? t("statusbar.disableWallpaper") : t("statusbar.enableWallpaper")
            toggleWallpaperItem.target = self
            wallpaperControlItems.append(toggleWallpaperItem)

            playPauseItem.isEnabled = hasWallpaper
            playPauseItem.title = (hasExternalWallpaper ? weBridge.isExternalPaused : videoWallpaperManager.isPaused)
                ? t("statusbar.resumeWallpaper")
                : t("statusbar.pauseWallpaper")
            playPauseItem.target = self
            wallpaperControlItems.append(playPauseItem)

            if !isExtensionMode,
               (hasNativeWallpaper || hasExternalWallpaper),
               let screen = activeScreens.first ?? screensToShow.first ?? NSScreen.screens.first {
                wallpaperControlItems.append(buildVolumeMenuItem(for: screen))
            }
        }

        // 将动态菜单项插入到 muteItem 之前（separator 之后）
        // 注意：每个显示器的音量滑块必须紧跟在该显示器的暂停/关闭项后面
        let separatorIndex = menu.index(of: muteItem)
        if separatorIndex != -1 {
            // 每次插入后重新获取 muteItem 的位置，确保后续项紧跟在前一项后面
            var currentInsertIndex = separatorIndex
            for item in wallpaperControlItems {
                menu.insertItem(item, at: currentInsertIndex)
                currentInsertIndex += 1
            }
        }

        // 桌面图标开关
        desktopIconsItem.title = DesktopIconManager.shared.areDesktopIconsHidden
            ? t("statusbar.showDesktopIcons")
            : t("statusbar.hideDesktopIcons")

        // 全局静音开关
        muteItem.isEnabled = hasNativeWallpaper || hasExternalWallpaper
        muteItem.title = videoWallpaperManager.isMuted ? t("statusbar.unmuteWallpaper") : t("statusbar.muteWallpaper")
    }

    @objc private func showMainWindow() {
        showWindowHandler?()
    }

    @objc private func openMyLibrary() {
        showWindowHandler?()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .switchToLibraryTab, object: nil)
        }
    }

    @objc private func releaseForegroundMemory() {
        releaseMemoryHandler?()
    }

    @objc private func perScreenTogglePlayback(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else {
            togglePlayback()
            return
        }

        if weBridge.isControllingExternalEngine {
            // CLI 壁纸暂不支持单屏暂停，走全局
            if weBridge.isExternalPaused {
                weBridge.resumeWallpaper()
            } else {
                weBridge.pauseWallpaper()
            }
            return
        }

        // macOS 26+：扩展控制模式下通过共享 prefs 控制 per-display 暂停
        if #available(macOS 26.0, *), videoWallpaperManager.isLockScreenMirroringActive {
            if let displayID = Self.cgDisplayID(for: screen) {
                let isPaused = LockScreenWallpaperService.shared.isDisplayPaused(displayID)
                LockScreenWallpaperService.shared.setDisplayPaused(!isPaused, forDisplayID: displayID)
            }
            return
        }

        if videoWallpaperManager.isPaused(on: screen) {
            videoWallpaperManager.resumeWallpaper(for: screen)
            DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
        } else {
            videoWallpaperManager.pauseWallpaper(for: screen)
        }
    }

    @objc private func perScreenToggleDynamicWallpaper(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else {
            toggleDynamicWallpaper()
            return
        }

        if weBridge.isControllingExternalEngine {
            // 关闭外部引擎壁纸（单屏）
            weBridge.ensureStoppedForNonCLIWallpaper(for: screen)
            return
        }

        // macOS 26+：扩展控制模式下停止单屏视频
        if #available(macOS 26.0, *), videoWallpaperManager.isLockScreenMirroringActive {
            videoWallpaperManager.stopWallpaper(for: screen)
            return
        }

        if videoWallpaperManager.hasActiveWallpaper(on: screen) {
            videoWallpaperManager.stopWallpaper(for: screen)
        }
    }

    @objc private func togglePlayback() {
        // 如果当前由 Wallpaper Engine X 接管，走 URL Scheme
        if weBridge.isControllingExternalEngine {
            if weBridge.isExternalPaused {
                weBridge.resumeWallpaper()
                DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            } else {
                weBridge.pauseWallpaper()
            }
            return
        }

        // macOS 26+：扩展控制模式下全局暂停/恢复
        if #available(macOS 26.0, *), videoWallpaperManager.isLockScreenMirroringActive {
            LockScreenWallpaperService.shared.setPaused(!videoWallpaperManager.isPaused)
            videoWallpaperManager.toggleExtensionGlobalPause()
            return
        }

        // 检测多显示器
        let screens = NSScreen.screens
        if screens.count > 1 && videoWallpaperManager.isVideoWallpaperActive {
            // 多显示器环境下显示选择弹窗
            DisplaySelectorManager.shared.showSelector(
                title: videoWallpaperManager.isPaused ? t("resumeWallpaper") : t("pauseWallpaper"),
                message: t("selectDisplayToControl")
            ) { [weak self] selectedScreen in
                guard let self = self else { return }

                if self.videoWallpaperManager.isPaused {
                    self.videoWallpaperManager.resumeWallpaper(for: selectedScreen)
                    DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
                } else {
                    self.videoWallpaperManager.pauseWallpaper(for: selectedScreen)
                }
            }
        } else {
            // 单显示器环境下直接操作
            if videoWallpaperManager.isPaused {
                videoWallpaperManager.resumeWallpaper()
                DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            } else {
                videoWallpaperManager.pauseWallpaper()
            }
        }
    }

    @objc private func toggleDynamicWallpaper() {
        if weBridge.isControllingExternalEngine {
            // 关闭外部引擎壁纸，但保留恢复记录，便于再次点击开启
            weBridge.disableWallpaperKeepingRestoreState()
            return
        }

        // macOS 26+：扩展控制模式下停止所有壁纸
        if #available(macOS 26.0, *), videoWallpaperManager.isLockScreenMirroringActive {
            videoWallpaperManager.stopWallpaper()
            return
        }

        if videoWallpaperManager.isVideoWallpaperActive {
            // 关闭动态壁纸
            videoWallpaperManager.stopWallpaper()
        } else {
            // 先尝试恢复上次保存的壁纸，没有则打开主窗口让用户选择
            videoWallpaperManager.restoreIfNeeded()
            if !videoWallpaperManager.isVideoWallpaperActive {
                Task { [weak self] in
                    guard let self else { return }
                    await self.weBridge.restoreIfNeeded()
                    if !self.weBridge.isControllingExternalEngine {
                        self.showWindowHandler?()
                    }
                }
            }
        }
    }

    @objc private func toggleMute() {
        // macOS 26+：扩展模式下静音对所有显示器生效（扩展不播放音频，但记录状态）
        if #available(macOS 26.0, *), videoWallpaperManager.isLockScreenMirroringActive {
            let newMuted = !videoWallpaperManager.isMuted
            videoWallpaperManager.setMuted(newMuted)
            // 同步到所有活跃显示器的 prefs
            for screen in NSScreen.screens {
                if let displayID = Self.cgDisplayID(for: screen) {
                    LockScreenWallpaperService.shared.setDisplayMuted(newMuted, forDisplayID: displayID)
                }
            }
            return
        }

        let newMuted = !videoWallpaperManager.isMuted
        videoWallpaperManager.setMuted(newMuted)
        if weBridge.isControllingExternalEngine {
            weBridge.setMuted(newMuted)
        }
    }

    @objc private func toggleDesktopIcons() {
        DesktopIconManager.shared.toggle()
        refreshMenuState()
    }

    @objc private func openWebWallpaperDesignPanel() {
        if let sceneWallpaperPath = currentSceneDesignWallpaperPath() {
            SceneWallpaperDesignPanelController.shared.present(for: sceneWallpaperPath)
            return
        }

        guard let wallpaperPath = weBridge.currentWallpaperPathForDesign else {
            NSSound.beep()
            return
        }
        if weBridge.isCurrentWallpaperWeb {
            WebWallpaperDesignPanelController.shared.present(for: wallpaperPath)
            return
        }
        if weBridge.isCurrentWallpaperScene {
            // 实时渲染模式下，显示属性编辑面板；否则显示文本设计面板
            if UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled") {
                SceneWallpaperPropertiesPanelController.shared.present(for: wallpaperPath)
            } else {
                SceneWallpaperDesignPanelController.shared.present(for: wallpaperPath)
            }
            return
        }
        NSSound.beep()
    }

    private func currentSceneDesignWallpaperPath() -> String? {
        guard let videoURL = videoWallpaperManager.currentVideoURL,
              let info = WallpaperDynamicTextParser.loadSidecar(for: videoURL),
              info.hasDynamicText,
              let wallpaperPath = info.wallpaperPath,
              !wallpaperPath.isEmpty else {
            return nil
        }
        return wallpaperPath
    }

    @objc private func quitApplication() {
        quitHandler?()
    }

    /// 从 NSScreen 获取 CGDirectDisplayID（用于 per-display prefs 的 key）
    private static func cgDisplayID(for screen: NSScreen) -> UInt32? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return screenNumber.uint32Value
    }
}

// MARK: - NSMenuDelegate
extension StatusBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
    }
}
