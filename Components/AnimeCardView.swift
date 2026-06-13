import SwiftUI
import AppKit
import Kingfisher

// MARK: - SwiftUI 动漫卡片

struct AnimeCardView: View, @preconcurrency Equatable {
    let anime: AnimeSearchResult
    let cardWidth: CGFloat
    let onTap: (() -> Void)?

    @State private var isHovered = false

    private let bottomBarHeight: CGFloat = 44
    private let cornerRadius: CGFloat = 14

    static func == (lhs: AnimeCardView, rhs: AnimeCardView) -> Bool {
        lhs.anime.id == rhs.anime.id &&
        lhs.cardWidth == rhs.cardWidth
    }

    /// 固定 10:14 竖版封面
    private var imageHeight: CGFloat {
        cardWidth * 1.4
    }

    private var cardHeight: CGFloat {
        imageHeight + bottomBarHeight
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                coverImage
                    .frame(width: cardWidth, height: imageHeight)

                bottomBar
                    .frame(height: bottomBarHeight)
            }
            .background(Color(hex: "1A1D24"))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)

            // 评分徽章
            if let rating = anime.rating, !rating.isEmpty {
                ratingBadge(rating)
                    .padding(8)
            }
        }
        .drawingGroup(opaque: true)
        .frame(width: cardWidth, height: cardHeight)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovered)
        .throttledHover(interval: 0.06) { isHovered = $0 }
    }

    @ViewBuilder
    private var coverImage: some View {
        let url: URL? = anime.coverURL.flatMap(URL.init(string:))
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let targetWidth = min(cardWidth * scale, 900)
        let targetHeight = min(imageHeight * scale, 1200)

        KFImage(url)
            .setProcessor(DownsamplingImageProcessor(size: CGSize(width: targetWidth, height: targetHeight)))
            // DownsamplingImageProcessor 已通过 CGImageSourceCreateThumbnailAtIndex 解码
            .cacheMemoryOnly(false)
            .memoryCacheExpiration(.seconds(300))
            .placeholder { Color.black.opacity(0.4) }
            .fade(duration: 0.25)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: cardWidth, height: imageHeight)
            .clipped()
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text(anime.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if let ep = anime.latestEpisode, !ep.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .regular))
                    Text(ep)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.46))
    }

    private func ratingBadge(_ rating: String) -> some View {
        HStack(spacing: 3) {
            Text("★")
                .font(.system(size: 8, weight: .regular))
                .foregroundColor(.yellow)
            Text(rating)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.black.opacity(0.5))
        )
    }
}
