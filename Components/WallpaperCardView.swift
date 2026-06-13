import SwiftUI
import Kingfisher
import QuartzCore

actor WallpaperForegroundImageLoadLimiter {
    static let shared = WallpaperForegroundImageLoadLimiter()

    private let maxConcurrentLoads = 4
    private var activeLoads = 0

    func tryAcquire() -> Bool {
        guard activeLoads < maxConcurrentLoads else { return false }
        activeLoads += 1
        return true
    }

    func release() {
        activeLoads = max(0, activeLoads - 1)
    }
}

@MainActor
enum WallpaperExploreScrollActivity {
    private static let idleDelay: CFTimeInterval = 0.22
    private static var lastScrollEventTime: CFTimeInterval = 0

    static func markActive() {
        lastScrollEventTime = CACurrentMediaTime()
    }

    static var isActive: Bool {
        CACurrentMediaTime() - lastScrollEventTime < idleDelay
    }

    static func waitUntilIdle() async {
        while isActive {
            let elapsed = CACurrentMediaTime() - lastScrollEventTime
            let remaining = max(0.04, idleDelay - elapsed)
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
        }
    }
}

// MARK: - SwiftUI 壁纸卡片

struct WallpaperCardView: View, @preconcurrency Equatable {
    let wallpaper: Wallpaper
    let isFavorite: Bool
    let cardWidth: CGFloat
    let onTap: (() -> Void)?

    @Environment(\.arcIsLightMode) private var isLightMode
    @State private var isHovered = false
    @State private var hasStartedImageLoading = false
    @State private var deferredImageLoadTask: Task<Void, Never>?
    @State private var holdsForegroundLoadPermit = false

    static let bottomBarHeight: CGFloat = 46
    private static let maxAspectRatioClamp: ClosedRange<CGFloat> = 0.35...3.6

    private let cornerRadius: CGFloat = 22

    static func == (lhs: WallpaperCardView, rhs: WallpaperCardView) -> Bool {
        lhs.wallpaper.id == rhs.wallpaper.id &&
        lhs.isFavorite == rhs.isFavorite &&
        lhs.cardWidth == rhs.cardWidth
    }

    static func effectiveAspectRatio(for wallpaper: Wallpaper) -> CGFloat {
        min(max(CGFloat(wallpaper.effectiveAspectRatioValue), maxAspectRatioClamp.lowerBound), maxAspectRatioClamp.upperBound)
    }

    static func imageHeight(cardWidth: CGFloat, wallpaper: Wallpaper) -> CGFloat {
        cardWidth / effectiveAspectRatio(for: wallpaper)
    }

    static func estimatedHeight(cardWidth: CGFloat, wallpaper: Wallpaper) -> CGFloat {
        imageHeight(cardWidth: cardWidth, wallpaper: wallpaper) + bottomBarHeight
    }

    private var effectiveAspectRatio: CGFloat {
        Self.effectiveAspectRatio(for: wallpaper)
    }

    private var imageHeight: CGFloat {
        Self.imageHeight(cardWidth: cardWidth, wallpaper: wallpaper)
    }

    private var cardHeight: CGFloat {
        Self.estimatedHeight(cardWidth: cardWidth, wallpaper: wallpaper)
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

    /// 探索网格优先滚动稳定性：只使用缩略图候选，避免高速滚动时触发原图下载/缓存。
    private static func computeCoverImageURL(wallpaper: Wallpaper) -> URL? {
        var seen: Set<String> = []
        for candidate in [wallpaper.thumbURL, wallpaper.smallThumbURL, wallpaper.originalThumbURL] {
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
                    .frame(height: Self.bottomBarHeight)
            }
            .background(Color(hex: "1A1D24"))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(borderColor, lineWidth: borderWidth)

            topLeadingBadges
                .padding(12)

            topTrailingBadge
                .padding(12)
        }
        .drawingGroup(opaque: true)
        .frame(width: cardWidth, height: cardHeight)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovered)
        // ⚡ 使用节流 hover 替代 .onHover，避免快速滚动时大量 hover 事件引发 body 重建风暴
        .modifier(WallpaperCardHoverModifier(isHovered: $isHovered))
        .onAppear {
            startImageLoadingWhenIdle()
        }
        .onDisappear {
            deferredImageLoadTask?.cancel()
            deferredImageLoadTask = nil
            releaseForegroundLoadPermitIfNeeded()
        }
    }

    private func startImageLoadingWhenIdle() {
        guard !hasStartedImageLoading else { return }
        deferredImageLoadTask?.cancel()

        if AppResponsivenessMonitor.isForegroundSettling {
            deferredImageLoadTask = Task { @MainActor in
                while !Task.isCancelled {
                    if await WallpaperForegroundImageLoadLimiter.shared.tryAcquire() {
                        holdsForegroundLoadPermit = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
                guard !Task.isCancelled else { return }
                beginImageLoadingAfterGuards()
            }
            return
        }

        beginImageLoadingAfterGuards()
    }

    private func beginImageLoadingAfterGuards() {
        if !WallpaperExploreScrollActivity.isActive {
            hasStartedImageLoading = true
            return
        }

        deferredImageLoadTask = Task { @MainActor in
            await WallpaperExploreScrollActivity.waitUntilIdle()
            guard !Task.isCancelled else { return }
            if !hasStartedImageLoading {
                hasStartedImageLoading = true
            }
            deferredImageLoadTask = nil
        }
    }

    private func releaseForegroundLoadPermitIfNeeded() {
        guard holdsForegroundLoadPermit else { return }
        holdsForegroundLoadPermit = false
        Task {
            await WallpaperForegroundImageLoadLimiter.shared.release()
        }
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

        if hasStartedImageLoading {
            KFImage(url)
                .setProcessor(processor)
                // DownsamplingImageProcessor 已通过 CGImageSourceCreateThumbnailAtIndex 解码
                // ⚡ LazyVStack 中不能使用 cancelOnDisappear(true)，滚出屏幕的 View 被销毁时
                // 图片下载被取消，滚回来时重新下载+解码，快速滚动下 CPU 100%。
                .memoryCacheExpiration(.seconds(300))
                .diskCacheExpiration(.days(7))
                .placeholder { imagePlaceholder }
                .onSuccess { _ in
                    releaseForegroundLoadPermitIfNeeded()
                }
                .onFailure { _ in
                    releaseForegroundLoadPermitIfNeeded()
                }
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: cardWidth, height: imageHeight)
                .clipped()
        } else {
            imagePlaceholder
                .frame(width: cardWidth, height: imageHeight)
        }
    }

    private var imagePlaceholder: some View {
        Rectangle()
            .fill(Color.black.opacity(0.4))
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
        .frame(height: Self.bottomBarHeight)
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
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.black.opacity(0.22))
        )
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
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.3))
            )
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

private struct WallpaperCardHoverModifier: ViewModifier {
    @Binding var isHovered: Bool

    func body(content: Content) -> some View {
        content.throttledHover(interval: 0.05) { hovering in
            if WallpaperExploreScrollActivity.isActive {
                if isHovered {
                    isHovered = false
                }
                return
            }
            isHovered = hovering
        }
    }
}
