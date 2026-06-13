import SwiftUI

// MARK: - 猜你喜欢覆盖层

struct GuessYouLikeOverlay: View {
    @ObservedObject var viewModel: GuessYouLikeViewModel
    let onDetail: (GuessYouLikeItem) -> Void
    let onDownload: (GuessYouLikeItem) -> Void

    init(
        viewModel: GuessYouLikeViewModel,
        onDetail: @escaping (GuessYouLikeItem) -> Void = { _ in },
        onDownload: @escaping (GuessYouLikeItem) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onDetail = onDetail
        self.onDownload = onDownload
    }

    private let cardW: CGFloat = 260
    private let cardH: CGFloat = 360
    private let columns = 4
    private let spacing: CGFloat = 18

    var body: some View {
        ZStack {
            // 半透明背景 — 点击关闭
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { viewModel.dismiss() }

            VStack(spacing: 0) {
                // 标题栏
                HStack(alignment: .center) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(LinearGradient(
                                colors: [.yellow, .orange, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                        Text(t("common.youMayLike"))
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Button { viewModel.dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 32, height: 32)
                            .detailGlassCircleChrome()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 40)
                .padding(.top, 60)
                .padding(.bottom, 16)

                // 卡片区域 — 每张卡独立延迟弹簧动画
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(cardW), spacing: spacing), count: columns),
                        spacing: spacing
                    ) {
                        ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { (i, item) in
                            GuessYouLikeCardCell(
                                item: item,
                                index: i,
                                dealt: viewModel.dealingProgress >= 1.0,
                                cardW: cardW,
                                cardH: cardH,
                                onDetail: { onDetail(item) },
                                onDownload: { onDownload(item) }
                            )
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 10)
                    .padding(.bottom, 30)
                }
            }
        }
        .transition(.opacity.animation(.easeOut(duration: 0.25)))
        .preferredColorScheme(.dark)
        .onKeyPress(.escape) {
            viewModel.dismiss()
            return .handled
        }
    }

}

// MARK: - 带独立动画状态的卡片 Cell
// 动画完成后移除动画修饰符，避免滚动时持续触发依赖检查

private struct GuessYouLikeCardCell: View {
    let item: GuessYouLikeItem
    let index: Int
    let dealt: Bool
    let cardW: CGFloat
    let cardH: CGFloat
    let onDetail: () -> Void
    let onDownload: () -> Void

    @State private var hasAnimated = false

    var body: some View {
        if hasAnimated {
            // 动画已完成：纯静态渲染，无动画修饰符开销
            GuessYouLikeCardView(
                item: item,
                onDetail: { _ in onDetail() },
                onDownload: { _ in onDownload() }
            )
            .frame(width: cardW, height: cardH)
        } else {
            // 动画中：附加发牌动画修饰符
            GuessYouLikeCardView(
                item: item,
                onDetail: { _ in onDetail() },
                onDownload: { _ in onDownload() }
            )
            .frame(width: cardW, height: cardH)
            .offset(y: dealt ? 0 : -320 - CGFloat(index) * 8)
            .scaleEffect(dealt ? 1.0 : 0.3)
            .opacity(dealt ? 1.0 : 0.0)
            .rotationEffect(.degrees(dealt ? 0 : (index.isMultiple(of: 2) ? 20 : -20)))
            .animation(
                .spring(response: 0.5, dampingFraction: 0.7)
                    .delay(Double(index) * 0.08),
                value: dealt
            )
            .onChange(of: dealt) { _, newValue in
                if newValue {
                    // 动画触发后，在预计完成时标记 hasAnimated
                    let delay = 0.5 + Double(index) * 0.08 + 0.1
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        hasAnimated = true
                    }
                }
            }
        }
    }
}
