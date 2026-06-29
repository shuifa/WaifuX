import SwiftUI
import Kingfisher

// MARK: - 猜你喜欢单张卡片

struct GuessYouLikeCardView: View {
    let item: GuessYouLikeItem
    let onDetail: (GuessYouLikeItem) -> Void
    let onDownload: (GuessYouLikeItem) -> Void

    @State private var hoverLocation: CGPoint = .zero
    @State private var isHovering: Bool = false
    // 记录 hover 开始时间，用于滚动时过滤误触发
    @State private var hoverStartTime: Date?

    private let maxTiltAngle: CGFloat = 6
    private let hoverDebounce: TimeInterval = 0.05
    // 固定卡片尺寸
    private let cardW: CGFloat = 260
    private let cardH: CGFloat = 360

    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(Color.black.opacity(0.6))
            .overlay(coverImage)
            .overlay(contentOverlay)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    // 防抖：首次进入 hover 时记录时间，短时间内不响应
                    if hoverStartTime == nil {
                        hoverStartTime = Date()
                        DispatchQueue.main.asyncAfter(deadline: .now() + hoverDebounce) {
                            guard hoverStartTime != nil else { return }
                            isHovering = true
                            hoverLocation = location
                        }
                    } else {
                        hoverLocation = location
                    }
                case .ended:
                    hoverStartTime = nil
                    isHovering = false
                    withAnimation(.easeOut(duration: 0.15)) {
                        hoverLocation = .zero
                    }
                }
            }
            .rotation3DEffect(rotationY, axis: (x: 0, y: 1, z: 0), perspective: 0.3)
            .rotation3DEffect(rotationX, axis: (x: 1, y: 0, z: 0), perspective: 0.3)
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }

    // MARK: - 内容层

    @ViewBuilder
    private var contentOverlay: some View {
        ZStack(alignment: .bottom) {
            // 底部渐变遮罩
            LinearGradient(
                gradient: Gradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.7)]),
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                // 顶部：来源标签 + 标题 + 详情按钮
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        // 来源标签
                        sourceTag
                        // 标题
                        Text(item.title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                        Text(item.subtitle)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    }
                    Spacer()
                    // 右上角液态玻璃圆形按钮 → 跳转详情
                    Button { onDetail(item) } label: {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 32, height: 32)
                            .detailGlassCircleChrome()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Spacer()

                // 底部：独立下载按钮（带边距，不延伸两边）
                Button { onDownload(item) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 11, weight: .semibold))
                        Text(t("download"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - 来源标签

    @ViewBuilder
    private var sourceTag: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(sourceColor.opacity(0.9))
                .frame(width: 6, height: 6)
            Text(item.sourceName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(.black.opacity(0.45))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var sourceColor: Color {
        switch item.sourceName {
        case "WallHaven": return Color(hex: "FF6B6B")
        case "4K Wallpapers": return Color(hex: "4ECDC4")
        case "MotionBG": return Color(hex: "45B7D1")
        case "Wallpaper Engine": return Color(hex: "96CEB4")
        case "DongTai": return Color(hex: "F472B6")
        case "Wallsflow": return Color(hex: "9B5DE5")
        default: return Color(hex: "DDA0DD")
        }
    }

    // MARK: - 封面图

    @ViewBuilder
    private var coverImage: some View {
        if let url = URL(string: item.imageURL), !item.imageURL.isEmpty {
            KFImage(url)
                .memoryCacheExpiration(.seconds(300))
                .placeholder { Color.black.opacity(0.3) }
                .fade(duration: 0.2)
                .resizable()
                .downsampling(size: CGSize(width: cardW * 2, height: cardH * 2))
                .aspectRatio(contentMode: .fill)
        }
    }

    // MARK: - 悬停倾斜（使用固定尺寸，避免 GeometryReader 开销）

    private var rotationY: Angle {
        guard isHovering else { return .zero }
        let nx = (hoverLocation.x / cardW - 0.5) * 2
        return .degrees(Double(nx * maxTiltAngle))
    }

    private var rotationX: Angle {
        guard isHovering else { return .zero }
        let ny = -(hoverLocation.y / cardH - 0.5) * 2
        return .degrees(Double(ny * maxTiltAngle))
    }
}

// MARK: - 预览

#Preview {
    GuessYouLikeCardView(
        item: GuessYouLikeItem.mockItems()[0],
        onDetail: { _ in },
        onDownload: { _ in }
    )
    .frame(width: 220, height: 310)
    .padding(40)
    .background(Color(hex: "0D0D0D"))
}
