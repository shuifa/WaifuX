import SwiftUI
import AppKit

/// 场景壁纸属性编辑面板（实时渲染模式下使用）
@MainActor
final class SceneWallpaperPropertiesPanelController {
    static let shared = SceneWallpaperPropertiesPanelController()

    private var windowController: NSWindowController?
    private var currentPath: String?

    private init() {}

    func present(for wallpaperPath: String) {
        if currentPath == wallpaperPath, let window = windowController?.window {
            anchorWindow(window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let viewModel = SceneWallpaperPropertiesViewModel(wallpaperPath: wallpaperPath) { [weak self] in
            self?.closePanel()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "设计场景"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.hasShadow = true
        window.backgroundColor = .clear
        window.setContentSize(NSSize(width: 360, height: 600))
        window.minSize = NSSize(width: 360, height: 600)
        window.maxSize = NSSize(width: 360, height: 600)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.level = .floating

        let rootView = SceneWallpaperPropertiesPanel(viewModel: viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hostingView
        anchorWindow(window)

        let controller = NSWindowController(window: window)
        windowController = controller
        currentPath = wallpaperPath
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func closePanel() {
        windowController?.close()
        windowController = nil
        currentPath = nil
    }

    private func anchorWindow(_ window: NSWindow) {
        guard let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame else {
            window.center()
            return
        }
        let origin = NSPoint(
            x: visibleFrame.minX + 20,
            y: visibleFrame.maxY - window.frame.height - 52
        )
        window.setFrameOrigin(origin)
    }
}

// MARK: - ViewModel

@MainActor
final class SceneWallpaperPropertiesViewModel: ObservableObject {
    struct PropertyRow: Identifiable {
        let id: String
        let property: SceneWallpaperProperty
        var currentValue: AnyCodableValue

        var isModified: Bool {
            property.originalValue != currentValue
        }
    }

    @Published private(set) var wallpaperName: String
    @Published var rows: [PropertyRow] = []

    let wallpaperPath: String
    private let onClose: () -> Void
    private var applyTask: Task<Void, Never>?

    init(wallpaperPath: String, onClose: @escaping () -> Void) {
        self.wallpaperPath = wallpaperPath
        self.onClose = onClose
        self.wallpaperName = SceneWallpaperDesignService.wallpaperTitle(for: wallpaperPath)
        load()
    }

    func load() {
        wallpaperName = SceneWallpaperDesignService.wallpaperTitle(for: wallpaperPath)
        let properties = SceneWallpaperPropertiesService.loadPropertiesWithOverrides(for: wallpaperPath)
        rows = properties.map { prop in
            PropertyRow(id: prop.key, property: prop, currentValue: prop.currentValue)
        }
    }

    func updateProperty(key: String, value: AnyCodableValue) {
        guard let index = rows.firstIndex(where: { $0.id == key }) else { return }
        rows[index].currentValue = value
        try? SceneWallpaperPropertiesService.setProperty(key: key, value: value, for: wallpaperPath)
        scheduleApply()
    }

    func resetProperty(key: String) {
        guard let index = rows.firstIndex(where: { $0.id == key }) else { return }
        rows[index].currentValue = rows[index].property.originalValue
        try? SceneWallpaperPropertiesService.resetProperty(key: key, for: wallpaperPath)
        scheduleApply()
    }

    func resetAll() {
        try? SceneWallpaperPropertiesService.resetAllProperties(for: wallpaperPath)
        load()
        scheduleApply()
    }

    private func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            guard let json = SceneWallpaperPropertiesService.propertiesOverrideJSON(for: wallpaperPath),
                  let data = json.data(using: .utf8),
                  var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            dict["__wallpaperPath"] = wallpaperPath
            DistributedNotificationCenter.default().post(
                name: NSNotification.Name("com.wallpaper-wgpu.updateUserProperties"),
                object: nil,
                userInfo: dict
            )
        }
    }

    func close() {
        onClose()
    }
}

// MARK: - Panel View

struct SceneWallpaperPropertiesPanel: View {
    @ObservedObject var viewModel: SceneWallpaperPropertiesViewModel
    private let accentTint = Color(nsColor: .controlAccentColor)
    private let labelWidth: CGFloat = 88

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 4)
            glassDivider

            if viewModel.rows.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.rows) { row in
                            propertyRow(row)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)

                glassDivider

                HStack {
                    resetButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .glassBackground()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(width: 360, height: 600)
        .tint(accentTint)
        .accentColor(accentTint)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accentTint)
                .frame(width: 26, height: 26)
                .background(accentTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(t("design.designScene"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)

                Text(viewModel.wallpaperName)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Button {
                viewModel.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LiquidGlassColors.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(accentTint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var glassDivider: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [accentTint.opacity(0.3), .white.opacity(0.06), accentTint.opacity(0.3)],
                startPoint: .leading,
                endPoint: .trailing
            ))
            .frame(height: 0.5)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14))
                    .foregroundStyle(accentTint)
                Text(t("design.noEditableSceneProps"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
            }
            Text(t("design.noScriptProperties"))
                .font(.system(size: 12))
                .foregroundStyle(LiquidGlassColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    private var resetButton: some View {
        Button {
            viewModel.resetAll()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                Text(t("design.resetToDefault"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(accentTint)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(accentTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Property Row

    @ViewBuilder
    private func propertyRow(_ row: SceneWallpaperPropertiesViewModel.PropertyRow) -> some View {
        switch row.property.type {
        case "slider":
            glassCard {
                sliderRow(
                    row.property.text ?? row.property.key,
                    value: sliderBinding(for: row),
                    text: sliderDisplayText(for: row),
                    range: (row.property.min ?? 0)...(row.property.max ?? 100),
                    step: row.property.step ?? 1
                )
            }
        case "bool", "toggle":
            glassCard {
                toggleRow(row.property.text ?? row.property.key, isOn: boolBinding(for: row))
            }
        case "color":
            glassCard {
                colorRow(row)
            }
        case "combo", "dropdown":
            glassCard {
                fieldRow(row.property.text ?? row.property.key) {
                    Picker("", selection: comboBinding(for: row)) {
                        ForEach(Array((row.property.options ?? [:]).keys.sorted()), id: \.self) { key in
                            Text(row.property.options?[key] ?? key).tag(key)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .tint(accentTint)
                    .accentColor(accentTint)
                }
            }
        default:
            glassCard {
                fieldRow(row.property.text ?? row.property.key) {
                    TextField("", text: textBinding(for: row))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                        .tint(accentTint)
                        .accentColor(accentTint)
                }
            }
        }
    }

    // MARK: - Bindings

    private func sliderBinding(for row: SceneWallpaperPropertiesViewModel.PropertyRow) -> Binding<Double> {
        Binding<Double>(
            get: {
                switch row.currentValue {
                case .number(let n): return n
                case .string(let s): return Double(s) ?? (row.property.min ?? 0)
                default: return row.property.min ?? 0
                }
            },
            set: { viewModel.updateProperty(key: row.id, value: .number($0)) }
        )
    }

    private func sliderDisplayText(for row: SceneWallpaperPropertiesViewModel.PropertyRow) -> String {
        let value: Double
        switch row.currentValue {
        case .number(let n): value = n
        case .string(let s): value = Double(s) ?? 0
        default: value = 0
        }
        if abs(value.rounded() - value) < 0.0001 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.2f", value)
    }

    private func boolBinding(for row: SceneWallpaperPropertiesViewModel.PropertyRow) -> Binding<Bool> {
        Binding<Bool>(
            get: {
                switch row.currentValue {
                case .bool(let b): return b
                case .string(let s): return s == "true"
                case .number(let n): return n != 0
                default: return false
                }
            },
            set: { viewModel.updateProperty(key: row.id, value: .bool($0)) }
        )
    }

    private func textBinding(for row: SceneWallpaperPropertiesViewModel.PropertyRow) -> Binding<String> {
        Binding<String>(
            get: { row.currentValue.stringValue },
            set: { viewModel.updateProperty(key: row.id, value: .string($0)) }
        )
    }

    private func comboBinding(for row: SceneWallpaperPropertiesViewModel.PropertyRow) -> Binding<String> {
        Binding<String>(
            get: { row.currentValue.stringValue },
            set: { viewModel.updateProperty(key: row.id, value: .string($0)) }
        )
    }

    // MARK: - Shared UI Components

    private func glassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.72)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(accentTint.opacity(0.2), lineWidth: 0.5)
                    )
            )
    }

    @ViewBuilder
    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        text: String,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                    .frame(width: labelWidth, alignment: .leading)
                Spacer(minLength: 0)
                Text(text)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accentTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accentTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Slider(value: value, in: range, step: step)
                .tint(accentTint)
                .accentColor(accentTint)
                .padding(.leading, labelWidth + 10)
        }
    }

    @ViewBuilder
    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textPrimary)
                .frame(width: labelWidth, alignment: .leading)
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(accentTint)
                .accentColor(accentTint)
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accentTint.opacity(isOn.wrappedValue ? 0.06 : 0))
        )
    }

    @ViewBuilder
    private func fieldRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textPrimary)
                .frame(width: labelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func colorRow(_ row: SceneWallpaperPropertiesViewModel.PropertyRow) -> some View {
        HStack(spacing: 10) {
            Text(row.property.text ?? row.property.key)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textPrimary)
                .frame(width: labelWidth, alignment: .leading)
            Spacer(minLength: 0)
            let selection = Binding<Color>(
                get: { Self.color(from: row.currentValue.stringValue) },
                set: { viewModel.updateProperty(key: row.id, value: .string(Self.string(from: $0))) }
            )
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selection.wrappedValue)
                    .frame(width: 54, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(accentTint.opacity(0.4), lineWidth: 1)
                    )
                ColorPicker("", selection: selection, supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 54, height: 24)
                    .opacity(0.02)
            }
        }
    }

    private static func color(from raw: String) -> Color {
        let numbers = raw
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Double($0) }
        guard numbers.count >= 3 else { return .white }
        return Color(
            .sRGB,
            red: numbers[0],
            green: numbers[1],
            blue: numbers[2],
            opacity: numbers.count >= 4 ? numbers[3] : 1
        )
    }

    private static func string(from color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(
            format: "%.5f %.5f %.5f",
            nsColor.redComponent,
            nsColor.greenComponent,
            nsColor.blueComponent
        )
    }
}

// MARK: - 玻璃背景修饰器
private extension View {
    func glassBackground() -> some View {
        self.background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
                    .opacity(0.82)

                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
        )
    }
}
