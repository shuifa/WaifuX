import SwiftUI

// MARK: - 弹幕视图

/// 弹幕显示视图（参考 Kazumi 的 canvas_danmaku）
///
/// 性能优化：
/// - 使用 Canvas 替代 ForEach + SwiftUI 视图，避免每帧 view diff 开销
/// - 位置按时间差实时计算，不存储可变位置状态
/// - 100ms Timer 仅用于清理过期弹幕和触发重绘，不修改弹幕数据
struct DanmakuView: View {
    let danmakuList: [Danmaku]
    @Binding var isEnabled: Bool
    @State var settings: DanmakuSettings = .default

    // 当前播放时间（秒）
    @Binding var currentTime: Double

    // 视图尺寸
    @State private var viewSize: CGSize = .zero

    // 活跃的弹幕项（只增删，不修改位置）
    @State private var activeItems: [DanmakuItem] = []

    // 轨道管理
    @State private var scrollTracks: [Int: Double] = [:]  // 轨道索引: 最后弹幕的结束时间
    @State private var topTracks: [Int: Bool] = [:]       // 轨道索引: 是否被占用
    @State private var bottomTracks: [Int: Bool] = [:]    // 轨道索引: 是否被占用

    // 定时器（仅用于清理过期弹幕；重绘由 TimelineView 驱动）
    @State private var timer: Timer?

    // 轨道配置
    private let trackHeight: Double = 30
    private let maxTracks = 15

    var body: some View {
        GeometryReader { geometry in
            // TimelineView 按固定间隔刷新其 content，从而驱动内部 Canvas 重绘。
            // 这样滚动弹幕位置（由 currentTime 实时计算）能持续刷新，
            // 而无需依赖 @State 变化触发 view diff。
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                // Canvas 绘制：直接在 GPU 层面绘制文字，避免 ForEach + SwiftUI View diff
                Canvas { context, size in
                    for item in activeItems {
                        let position = computePosition(for: item, in: size)
                        // 只绘制在可见区域内的弹幕
                        guard position.x > -200, position.x < size.width + 200 else { continue }

                        let resolved = context.resolve(Text(item.danmaku.text)
                            .font(.system(size: settings.fontSize, weight: .medium))
                            .foregroundColor(danmakuColor(for: item)))

                        context.draw(resolved, at: position, anchor: .center)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .onChange(of: geometry.size) { _, newSize in
                viewSize = newSize
                initializeTracks()
            }
            .onAppear {
                viewSize = geometry.size
                initializeTracks()
                startTimer()
            }
            .onDisappear {
                stopTimer()
            }
            .onChange(of: currentTime) { _, newTime in
                updateDanmaku(for: newTime)
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    activeItems.removeAll()
                }
            }
        }
    }

    // MARK: - 位置计算（纯函数，不修改状态）

    /// 根据弹幕创建时间和当前播放时间，实时计算滚动弹幕的 X 坐标
    private func computePosition(for item: DanmakuItem, in size: CGSize) -> CGPoint {
        switch item.danmaku.mode {
        case .scroll:
            let textWidth = estimateTextWidth(item.danmaku.text)
            let startX = size.width + textWidth / 2
            let endX = -textWidth / 2
            let duration = Double(item.danmaku.text.count) * 0.15 / settings.speed + 5.0
            let elapsed = currentTime - item.danmaku.time
            let progress = max(0, elapsed) / duration
            let x = startX + (endX - startX) * progress
            return CGPoint(x: x, y: item.y)
        case .top, .bottom:
            return CGPoint(x: size.width / 2, y: item.y)
        }
    }

    /// 计算弹幕颜色
    private func danmakuColor(for item: DanmakuItem) -> Color {
        let colorInfo = item.danmaku.color
        return Color(red: colorInfo.r, green: colorInfo.g, blue: colorInfo.b)
            .opacity(settings.opacity)
    }

    // MARK: - 轨道管理

    private func initializeTracks() {
        let trackCount = min(maxTracks, Int(viewSize.height / trackHeight))
        scrollTracks = Dictionary(uniqueKeysWithValues: (0..<trackCount).map { ($0, 0) })
        topTracks = Dictionary(uniqueKeysWithValues: (0..<trackCount).map { ($0, false) })
        bottomTracks = Dictionary(uniqueKeysWithValues: (0..<trackCount).map { ($0, false) })
    }

    // MARK: - 弹幕更新

    private func updateDanmaku(for time: Double) {
        guard isEnabled else { return }

        // 找到当前时间应该显示的弹幕
        let windowStart = time - 1.0  // 提前1秒准备
        let windowEnd = time + 0.5    // 允许0.5秒的延迟

        let newDanmaku = danmakuList.filter { danmaku in
            danmaku.time >= windowStart &&
            danmaku.time <= windowEnd &&
            !activeItems.contains(where: { $0.danmaku.time == danmaku.time && $0.danmaku.text == danmaku.text })
        }

        // 根据设置过滤
        let filteredDanmaku = newDanmaku.filter { danmaku in
            switch danmaku.mode {
            case .scroll:
                return settings.enableScroll
            case .top:
                return settings.enableTop
            case .bottom:
                return settings.enableBottom
            }
        }

        // 添加到活跃列表
        for danmaku in filteredDanmaku {
            if let item = createDanmakuItem(danmaku: danmaku, currentTime: time) {
                activeItems.append(item)
            }
        }

        // 清理过期的弹幕
        cleanupExpiredDanmaku(currentTime: time)
    }

    private func createDanmakuItem(danmaku: Danmaku, currentTime: Double) -> DanmakuItem? {
        switch danmaku.mode {
        case .scroll:
            return createScrollItem(danmaku: danmaku)
        case .top:
            return createTopItem(danmaku: danmaku)
        case .bottom:
            return createBottomItem(danmaku: danmaku)
        }
    }

    private func createScrollItem(danmaku: Danmaku) -> DanmakuItem? {
        guard let trackIndex = findAvailableScrollTrack() else { return nil }

        let duration = Double(danmaku.text.count) * 0.15 / settings.speed + 5.0
        let y = Double(trackIndex) * trackHeight + trackHeight / 2

        // 更新轨道状态（记录结束时间）
        let endTime = Date().timeIntervalSince1970 + duration
        scrollTracks[trackIndex] = endTime

        return DanmakuItem(danmaku: danmaku, x: 0, y: y)
    }

    private func createTopItem(danmaku: Danmaku) -> DanmakuItem? {
        guard let trackIndex = findAvailableFixedTrack(tracks: &topTracks) else { return nil }

        let y = Double(trackIndex) * trackHeight + trackHeight / 2

        // 3秒后释放轨道
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            topTracks[trackIndex] = false
        }

        return DanmakuItem(danmaku: danmaku, x: 0, y: y)
    }

    private func createBottomItem(danmaku: Danmaku) -> DanmakuItem? {
        guard let trackIndex = findAvailableFixedTrack(tracks: &bottomTracks) else { return nil }

        // 从底部往上计算
        let y = viewSize.height - (Double(trackIndex) * trackHeight + trackHeight / 2)

        // 3秒后释放轨道
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            bottomTracks[trackIndex] = false
        }

        return DanmakuItem(danmaku: danmaku, x: 0, y: y)
    }

    private func findAvailableScrollTrack() -> Int? {
        let currentTime = Date().timeIntervalSince1970

        // 找到最早可用的轨道
        return scrollTracks
            .filter { $0.value <= currentTime }
            .min(by: { $0.value < $1.value })?
            .key
    }

    private func findAvailableFixedTrack(tracks: inout [Int: Bool]) -> Int? {
        return tracks.first { !$0.value }?.key
    }

    private func cleanupExpiredDanmaku(currentTime: Double) {
        let duration = 10.0  // 弹幕最大存活时间

        activeItems.removeAll { item in
            let age = currentTime - item.danmaku.time
            return age > duration
        }
    }

    // MARK: - 定时器（仅用于清理过期弹幕；重绘由 TimelineView 驱动）

    private func startTimer() {
        Task { @MainActor in
            // 100ms 定时器：清理过期弹幕（Canvas 重绘由 TimelineView 负责）
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                Task { @MainActor in
                    cleanupExpiredDanmaku(currentTime: currentTime)
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 辅助方法

    private func estimateTextWidth(_ text: String) -> Double {
        let charWidth = settings.fontSize * 0.8
        return Double(text.count) * charWidth
    }
}

// MARK: - 弹幕控制面板

struct DanmakuControlPanel: View {
    @Binding var settings: DanmakuSettings
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            // 标题栏
            HStack {
                Text(t("danmaku.settings"))
                    .font(.headline)
                Spacer()
                Button(t("done")) {
                    isPresented = false
                }
            }
            .padding(.horizontal)

            Divider()

            // 开关
            DanmakuLiquidToggle(t("danmaku.enableDanmaku"), isOn: $settings.isEnabled)
                .padding(.horizontal)

            Divider()

            // 速度
            VStack(alignment: .leading) {
                HStack {
                    Text(t("danmaku.speed"))
                    Spacer()
                    Text("\(String(format: "%.1f", settings.speed))x")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.speed, in: 0.5...2.0, step: 0.1)
                    .tint(LiquidGlassColors.primaryPink)
            }
            .padding(.horizontal)

            // 透明度
            VStack(alignment: .leading) {
                HStack {
                    Text(t("danmaku.opacity"))
                    Spacer()
                    Text("\(Int(settings.opacity * 100))%")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.opacity, in: 0.1...1.0, step: 0.1)
                    .tint(LiquidGlassColors.primaryPink)
            }
            .padding(.horizontal)

            // 字体大小
            VStack(alignment: .leading) {
                HStack {
                    Text(t("danmaku.fontSize"))
                    Spacer()
                    Text("\(Int(settings.fontSize))px")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.fontSize, in: 12...24, step: 1)
                    .tint(LiquidGlassColors.primaryPink)
            }
            .padding(.horizontal)

            Divider()

            // 显示选项
            VStack(alignment: .leading, spacing: 10) {
                Text(t("danmaku.displayOptions"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                DanmakuLiquidToggle(t("danmaku.scroll"), isOn: $settings.enableScroll)
                DanmakuLiquidToggle(t("danmaku.top"), isOn: $settings.enableTop)
                DanmakuLiquidToggle(t("danmaku.bottom"), isOn: $settings.enableBottom)
                DanmakuLiquidToggle(t("danmaku.deduplication"), isOn: $settings.enableDeduplication)
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding(.vertical)
        .frame(width: 300)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
    }
}

// MARK: - 弹幕液态玻璃 Toggle
private struct DanmakuLiquidToggle: View {
    let title: String
    @Binding var isOn: Bool
    @State private var isHovered = false
    @State private var isPressed = false

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn ? Color(hex: "FF3366") : .white.opacity(0.4))
                    .contentTransition(.symbolEffect(.replace))

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }

            Spacer()

            // 液态玻璃开关
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    isOn.toggle()
                }
            }) {
                ZStack {
                    Capsule()
                        .fill(isOn ? Color(hex: "FF3366").opacity(0.35) : Color.white.opacity(0.12))
                        .frame(width: 40, height: 22)

                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
                        .offset(x: isOn ? 9 : -9)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
                        )
                }
            }
            .buttonStyle(.plain)
            .scaleEffect(isPressed ? 0.92 : 1.0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 弹幕开关按钮

struct DanmakuToggleButton: View {
    @Binding var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isEnabled ? "text.bubble.fill" : "text.bubble")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isEnabled ? .yellow : .white)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 预览

#Preview {
    ZStack {
        Color.black

        DanmakuView(
            danmakuList: [
                Danmaku(text: "测试弹幕1", time: 0, mode: .scroll, color: 0xFFFFFF),
                Danmaku(text: "测试弹幕2", time: 1, mode: .scroll, color: 0xFF0000),
                Danmaku(text: "顶部弹幕", time: 2, mode: .top, color: 0x00FF00),
                Danmaku(text: "底部弹幕", time: 3, mode: .bottom, color: 0x0000FF),
            ],
            isEnabled: .constant(true),
            currentTime: .constant(0)
        )
    }
    .frame(width: 800, height: 400)
}
