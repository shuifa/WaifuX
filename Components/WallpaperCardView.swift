import SwiftUI
import Kingfisher

// MARK: - SwiftUI 壁纸卡片

struct WallpaperCardView: View {
    let wallpaper: Wallpaper
    let isFavorite: Bool
    let cardWidth: CGFloat
    let onTap: (() -> Void)?

    @Environment(\.arcIsLightMode) private var isLightMode
    @State private var isHovered = false

    private let bottomBarHeight: CGFloat = 46
    private let cornerRadius: CGFloat = 22

    private var effectiveAspectRatio: CGFloat {
        min(max(CGFloat(wallpaper.effectiveAspectRatioValue), 0.35), 3.6)
    }

    private var imageHeight: CGFloat {
        cardWidth / effectiveAspectRatio
    }

    private var cardHeight: CGFloat {
        imageHeight + bottomBarHeight
    }

    private var primaryTextColor: Color {
        isLightMode ? Color(hex: "1A1A1A").opacity(0.9) : .white.opacity(0.9)
    }

    private var secondaryTextColor: Color {
        isLightMode ? Color(hex: "666666").opacity(0.78) : .white.opacity(0.5)
    }

    private var badgeTextColor: Color {
        isLightMode ? Color(hex: "666666").opacity(0.9) : .white.opacity(0.82)
    }

    private var borderColor: Color {
        switch wallpaper.purity.lowercased() {
        case "nsfw":  return Color(hex: "FF3B30")
        case "sketchy": return Color(hex: "FFB347")
        default:       return Color.white.opacity(0.08)
        }
    }

    private var borderWidth: CGFloat {
        switch wallpaper.purity.lowercased() {
        case "nsfw", "sketchy": return 1.5
        default:                return 1
        }
    }

    /// 计算封面图 URL（静态方法，无捕获开销）
    private static func computeCoverImageURL(wallpaper: Wallpaper) -> URL? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let aspectRatio = min(max(CGFloat(wallpaper.effectiveAspectRatioValue), 0.35), 3.6)
        let isExtremeAspect = aspectRatio < 0.7 || aspectRatio > 2.1
        let preferHighRes = isExtremeAspect || (scale >= 2)

        let candidates: [URL?]
        if preferHighRes {
            if wallpaper.source == "4kwallpapers" {
                candidates = [wallpaper.thumbURL, wallpaper.originalThumbURL, wallpaper.fullImageURL, wallpaper.smallThumbURL]
            } else {
                candidates = [wallpaper.originalThumbURL, wallpaper.thumbURL, wallpaper.fullImageURL, wallpaper.smallThumbURL]
            }
        } else {
            candidates = [wallpaper.thumbURL, wallpaper.originalThumbURL, wallpaper.smallThumbURL, wallpaper.fullImageURL]
        }

        var seen: Set<String> = []
        for candidate in candidates {
            guard let url = candidate else { continue }
            guard seen.insert(url.absoluteString).inserted else { continue }
            return url
        }
        return nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                coverImage
                    .frame(width: cardWidth, height: imageHeight)

                bottomBar
                    .frame(height: bottomBarHeight)
            }
            .background(Color(hex: "1A1D24").opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(borderColor, lineWidth: borderWidth)

            topLeadingBadges
                .padding(12)

            topTrailingBadge
                .padding(12)
        }
        .frame(width: cardWidth, height: cardHeight)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
    }

    // MARK: - Cover Image

    @ViewBuilder
    private var coverImage: some View {
        let url = Self.computeCoverImageURL(wallpaper: wallpaper)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let targetWidth = cardWidth * scale
        let targetHeight = (cardWidth / effectiveAspectRatio) * scale
        let maxEdge: CGFloat = 1280
        let reduction = max(targetWidth, targetHeight) > maxEdge
            ? maxEdge / max(targetWidth, targetHeight) : 1
        let targetSize = CGSize(
            width: targetWidth * reduction,
            height: targetHeight * reduction
        )
        let processor = DownsamplingImageProcessor(size: targetSize)

        KFImage(url)
            .setProcessor(processor)
            .backgroundDecode()
            .cacheOriginalImage()
            .memoryCacheExpiration(.seconds(300))
            .diskCacheExpiration(.days(7))
            .placeholder { Color.black.opacity(0.4) }
            .fade(duration: 0.25)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: cardWidth, height: imageHeight)
            .clipped()
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text(wallpaper.uploader?.username ?? wallpaper.categoryDisplayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(primaryTextColor)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if let hex = wallpaper.primaryColorHex, !hex.isEmpty {
                colorChip(hex: hex)
            }

            statView(
                symbol: "heart.fill",
                value: compactNumber(wallpaper.favorites),
                tint: isFavorite ? Color(hex: "FF5A7D") : secondaryTextColor
            )

            statView(
                symbol: "eye.fill",
                value: compactNumber(wallpaper.views),
                tint: secondaryTextColor
            )
        }
        .padding(.horizontal, 14)
        .frame(height: bottomBarHeight)
    }

    private func colorChip(hex: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.5))
            Text("#\(hex)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(badgeTextColor)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Color.black.opacity(0.22))
        .cornerRadius(11)
    }

    private func statView(symbol: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .default))
        }
        .foregroundColor(tint)
    }

    // MARK: - Badges

    private var topLeadingBadges: some View {
        HStack(spacing: 8) {
            if !wallpaper.categoryDisplayName.isEmpty {
                badgeText(wallpaper.categoryDisplayName)
            }
            if !wallpaper.purityDisplayName.isEmpty {
                badgeText(wallpaper.purityDisplayName)
            }
        }
    }

    private var topTrailingBadge: some View {
        HStack {
            Spacer()
            let label = wallpaper.effectiveResolutionLabel
                .replacingOccurrences(of: "x", with: "×")
            if !label.isEmpty {
                badgeText(label)
            }
        }
    }

    private func badgeText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(badgeTextColor)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Color.black.opacity(0.3))
            .cornerRadius(10)
    }

    // MARK: - Helpers

    private func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
