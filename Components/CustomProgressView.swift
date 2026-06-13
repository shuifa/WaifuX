import SwiftUI

// MARK: - 自定义加载指示器（解决 ProgressView 尺寸约束警告）
struct CustomProgressView: View {
    var tint: Color = .white
    var scale: CGFloat = 1.0

    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.3), lineWidth: 2)
                .frame(width: 20 * scale, height: 20 * scale)

            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 20 * scale, height: 20 * scale)
                .rotationEffect(Angle(degrees: rotation))
        }
        .onAppear {
            rotation = 360
        }
        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: rotation)
    }
}

// MARK: - 简化的加载点（用于更小的占位）
struct LoadingDots: View {
    var tint: Color = .white.opacity(0.72)

    @State private var animatingDot = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animatingDot == index ? 1.2 : 0.8)
                    .opacity(animatingDot == index ? 1.0 : 0.5)
            }
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 0.4)
                .repeatForever(autoreverses: true)
            ) {
                animatingDot = 2
            }
        }
    }
}

// MARK: - 带固定尺寸的 ProgressView 包装器
struct FixedProgressView: View {
    var tint: Color = .white

    var body: some View {
        ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: tint))
            .frame(width: 24, height: 24)
            .fixedSize()
    }
}

struct ExploreLoadingStateView: View {
    var message: String = "加载中..."
    var tint: Color = .white

    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 18) {
            ExploreLoadingGlyph(tint: tint)

            Text(message)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(tint.opacity(0.88))
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(tint.opacity(index == 1 ? 0.52 : 0.30))
                        .frame(width: index == 1 ? 20 : 12, height: 2)
                        .opacity(isAnimating ? 0.9 : 0.35)
                        .scaleEffect(x: isAnimating ? 1.0 : 0.72, anchor: .center)
                        .animation(
                            .easeInOut(duration: 0.9)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.12),
                            value: isAnimating
                        )
                }
            }
        }
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, minHeight: 190)
        .onAppear { isAnimating = true }
        .onDisappear { isAnimating = false }
    }
}

struct ExploreLoadingGlyph: View {
    var tint: Color = .white
    var compact: Bool = false

    @State private var isAnimating = false

    private var glyphSize: CGSize {
        compact ? CGSize(width: 44, height: 30) : CGSize(width: 92, height: 70)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 9 : 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            tint.opacity(isAnimating ? 0.58 : 0.22),
                            Color.white.opacity(compact ? 0.18 : 0.28),
                            tint.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: compact ? 0.75 : 1
                )
                .frame(
                    width: compact ? 38 : 70,
                    height: compact ? 22 : 42
                )
                .scaleEffect(isAnimating ? 1.04 : 0.97)
                .animation(
                    .easeInOut(duration: 1.25).repeatForever(autoreverses: true),
                    value: isAnimating
                )

            ForEach(0..<3, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(compact ? 0.70 : 0.84),
                                tint.opacity(index == 1 ? 0.88 : 0.62)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(
                        width: lineWidth(for: index),
                        height: compact ? 2.6 : 4
                    )
                    .offset(y: CGFloat(index - 1) * (compact ? 5.2 : 9))
                    .scaleEffect(
                        x: isAnimating ? lineScaleOn(for: index) : lineScaleOff(for: index),
                        y: 1,
                        anchor: index == 1 ? .center : (index == 0 ? .leading : .trailing)
                    )
                    .opacity(isAnimating ? 0.92 : 0.46)
                    .animation(
                        .easeInOut(duration: 0.95)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.14),
                        value: isAnimating
                    )
            }
        }
        .frame(width: glyphSize.width, height: glyphSize.height)
        .contentShape(Rectangle())
        .onAppear { isAnimating = true }
        .onDisappear { isAnimating = false }
    }

    private func lineWidth(for index: Int) -> CGFloat {
        let base: [CGFloat] = compact ? [21, 28, 17] : [46, 58, 36]
        return base[index]
    }

    private func lineScaleOn(for index: Int) -> CGFloat {
        let scales: [CGFloat] = compact ? [0.78, 1.08, 0.88] : [0.82, 1.10, 0.86]
        return scales[index]
    }

    private func lineScaleOff(for index: Int) -> CGFloat {
        let scales: [CGFloat] = compact ? [1.12, 0.80, 1.16] : [1.08, 0.76, 1.12]
        return scales[index]
    }
}

// MARK: - 液态玻璃线性进度条（简约风格）
struct LiquidGlassLinearProgressBar: View {
    let progress: Double
    var height: CGFloat = 6
    var tintColor: Color = LiquidGlassColors.primaryPink
    var trackOpacity: Double = 0.15

    var body: some View {
        GeometryReader { proxy in
            let clampedProgress = max(0, min(progress, 1))
            let fillWidth = max(height, proxy.size.width * clampedProgress)

            ZStack(alignment: .leading) {
                // 轨道 - 液态玻璃效果
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(trackOpacity)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )

                // 填充 - 简约单色
                Capsule(style: .continuous)
                    .fill(tintColor.opacity(0.85))
                    .frame(width: fillWidth)
                    .overlay(
                        // 液态玻璃高光
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.4),
                                        Color.white.opacity(0.1),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: fillWidth)
                    )
            }
        }
        .frame(height: height)
        // 关键优化：使用 drawingGroup 将视图渲染为单个纹理，避免离屏渲染导致的卡顿
        .drawingGroup(opaque: false)
    }
}
