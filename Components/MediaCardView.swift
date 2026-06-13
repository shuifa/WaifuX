import SwiftUI
import Kingfisher

// MARK: - 滚动状态追踪（媒体探索页）

enum MediaExploreScrollActivity {
    private static let idleDelay: CFTimeInterval = 0.22
    @MainActor private static var lastScrollEventTime: CFTimeInterval = 0

    @MainActor
    static func markActive() {
        lastScrollEventTime = CACurrentMediaTime()
    }

    @MainActor
    static var isActive: Bool {
        CACurrentMediaTime() - lastScrollEventTime < idleDelay
    }
}

// MARK: - NativeGIFView（CALayer 直通，绕过 SwiftUI 重绘）

/// 用 NSViewRepresentable 封装 GIF 宿主，帧更新直接写 `layer.contents`，
/// 完全绕过 SwiftUI 的 Body 评估和 Diff 算法。
/// 滚动时 `isPlaying = false` → 纯静态图层，零 CPU 消耗。
struct NativeGIFView: NSViewRepresentable {
    let url: URL
    let isPlaying: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspectFill
        view.layer?.isOpaque = true
        context.coordinator.load(url: url)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.layer = nsView.layer
        if isPlaying {
            context.coordinator.startAnimation()
        } else {
            context.coordinator.stopAnimation()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopAnimation()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: @unchecked Sendable {
        weak var layer: CALayer?
        private var imageSource: CGImageSource?
        private var frames: [(image: CGImage, duration: TimeInterval)] = []
        private var timer: Timer?
        private var currentFrameIndex = 0
        private var loadTask: Task<Void, Never>?
        private var isLoaded = false

        func load(url: URL) {
            loadTask?.cancel()
            frames = []
            imageSource = nil
            isLoaded = false
            timer?.invalidate()
            timer = nil

            loadTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      !data.isEmpty else { return }
                guard !Task.isCancelled else { return }
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
                let count = CGImageSourceGetCount(source)
                guard count > 1 else {
                    if let img = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                        await MainActor.run { [weak self] in
                            self?.layer?.contents = img
                            self?.isLoaded = true
                        }
                    }
                    return
                }

                let maxFrames = 20
                let frameStep = max(1, count / maxFrames)
                var decoded: [(CGImage, TimeInterval)] = []
                var i = 0
                while i < count, decoded.count < maxFrames {
                    let dur = Self.frameDuration(at: i, source: source)
                    let opts: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 512,
                        kCGImageSourceCreateThumbnailWithTransform: true
                    ]
                    if let thumb = CGImageSourceCreateThumbnailAtIndex(source, i, opts as CFDictionary) {
                        decoded.append((thumb, dur))
                    }
                    i += frameStep
                }

                guard !decoded.isEmpty, !Task.isCancelled else { return }
                let frames = decoded
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.frames = frames
                    self.imageSource = source
                    self.isLoaded = true
                    self.layer?.contents = frames[0].0
                }
            }
        }

        func startAnimation() {
            guard timer == nil, !frames.isEmpty else { return }
            scheduleNextFrame()
        }

        func stopAnimation() {
            timer?.invalidate()
            timer = nil
        }

        private func scheduleNextFrame() {
            guard !frames.isEmpty else { return }
            let dur = max(frames[currentFrameIndex].duration, 0.05)
            timer = Timer.scheduledTimer(withTimeInterval: dur, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.currentFrameIndex = (self.currentFrameIndex + 1) % self.frames.count
                self.layer?.contents = self.frames[self.currentFrameIndex].0
                self.scheduleNextFrame()
            }
        }

        private static func frameDuration(at index: Int, source: CGImageSource) -> TimeInterval {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let gifProps = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
            if let dur = gifProps[kCGImagePropertyGIFDelayTime] as? NSNumber, dur.doubleValue > 0 { return dur.doubleValue }
            if let dur = gifProps[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber, dur.doubleValue > 0 { return dur.doubleValue }
            return 0.1
        }
    }
}

// MARK: - SwiftUI 媒体卡片

struct MediaCardView: View, @preconcurrency Equatable {
    let media: MediaItem
    let isFavorite: Bool
    let cardWidth: CGFloat
    let onTap: (() -> Void)?

    @State private var animatedProbeResult: AnimatedProbeResult?
    @State private var isHovered = false
    @Environment(\.coverGIFPlaybackHostActive) private var coverGIFPlaybackHostActive

    private let bottomBarHeight: CGFloat = 44
    private let cornerRadius: CGFloat = 16
    private let maxAnimatedGIFBytes: Int64 = 32 * 1024 * 1024

    static func == (lhs: MediaCardView, rhs: MediaCardView) -> Bool {
        lhs.media.id == rhs.media.id &&
        lhs.isFavorite == rhs.isFavorite &&
        lhs.cardWidth == rhs.cardWidth
    }

    private var effectiveAspectRatio: CGFloat {
        let raw = media.exactResolution ?? media.resolutionLabel
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "X", with: "x")
        let parts = raw.split(separator: "x")
        if parts.count == 2,
           let w = Double(parts[0]), w > 0,
           let h = Double(parts[1]), h > 0 {
            let aspect = CGFloat(w / h)
            return min(max(aspect, 0.35), 3.6)
        }
        return 1.6
    }

    private var imageHeight: CGFloat {
        let maxImageHeight: CGFloat = cardWidth * 1.8
        return min(cardWidth / effectiveAspectRatio, maxImageHeight)
    }

    private var cardHeight: CGFloat {
        imageHeight + bottomBarHeight
    }

    private var staticDisplayURL: URL {
        media.coverImageURL
    }

    private var animatedDisplayURL: URL? {
        animatedProbeResult?.animatedURL
    }

    private var shouldAnimateGIF: Bool {
        coverGIFPlaybackHostActive && !MediaExploreScrollActivity.isActive
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                coverImage
                    .frame(width: cardWidth, height: imageHeight)
                    .task(id: media.id) {
                        animatedProbeResult = nil
                        let result = await probeAnimatedImage()
                        guard !Task.isCancelled else { return }
                        animatedProbeResult = result
                    }

                bottomBar
                    .frame(height: bottomBarHeight)
            }
            .background(Color(hex: "1C2431"))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(
                color: Color.black.opacity(0.16),
                radius: 8,
                x: 0,
                y: 5
            )

            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    Color.white.opacity(isHovered ? 0.18 : 0.06),
                    lineWidth: isHovered ? 1.25 : 1
                )

            badgesView
                .padding(10)
        }
        .frame(width: cardWidth, height: cardHeight)
        .contentShape(Rectangle())
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            isHovered = hovering
        }
        .zIndex(isHovered ? 1 : 0)
        .onTapGesture { onTap?() }
        .onReceive(NotificationCenter.default.publisher(for: .appShouldReleaseForegroundMemory)) { _ in
            animatedProbeResult = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDidReceiveMemoryPressure)) { _ in
            animatedProbeResult = nil
        }
    }

    @ViewBuilder
    private var coverImage: some View {
        if let animatedURL = animatedDisplayURL {
            NativeGIFView(url: animatedURL, isPlaying: shouldAnimateGIF)
                .frame(width: cardWidth, height: imageHeight)
                .clipped()
        } else {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let targetSize = CGSize(
                width: min(cardWidth * scale, 1600),
                height: min(imageHeight * scale, 1600)
            )
            KFImage(staticDisplayURL)
                .setProcessor(DownsamplingImageProcessor(size: targetSize))
                .cacheMemoryOnly(false)
                .memoryCacheExpiration(.seconds(300))
                .fade(duration: 0.25)
                .placeholder { _ in Color.black.opacity(0.4) }
                .resizable()
                .scaledToFill()
                .frame(width: cardWidth, height: imageHeight)
                .clipped()
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text(media.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isFavorite ? Color(hex: "FF5A7D") : .white.opacity(0.36))
            }
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(Color(hex: "1A1D24"))
        .drawingGroup(opaque: true)
    }

    @ViewBuilder
    private var badgesView: some View {
        HStack(alignment: .top) {
            let firstTag = media.primaryTagText
            if !firstTag.isEmpty {
                badgeText(firstTag)
            }

            Spacer()

            if !media.resolutionLabel.isEmpty {
                badgeText(media.resolutionLabel.replacingOccurrences(of: "x", with: "×"))
            }
        }
        .drawingGroup(opaque: true)
    }

    private func badgeText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color(hex: "1A1D24"))
            )
    }

    private struct AnimatedProbeResult: Equatable {
        let animatedURL: URL?
    }

    private func probeAnimatedImage() async -> AnimatedProbeResult {
        for url in animatedProbeCandidates {
            guard !Task.isCancelled else { return AnimatedProbeResult(animatedURL: nil) }
            if await AnimatedImageProbeCache.shared.isAnimatedGIF(url, maxByteCount: maxAnimatedGIFBytes) {
                return AnimatedProbeResult(animatedURL: url)
            }
        }
        return AnimatedProbeResult(animatedURL: nil)
    }

    private var animatedProbeCandidates: [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        let candidates = [
            media.posterURLValue,
            Optional(media.thumbnailURLValue),
            Optional(media.coverImageURL)
        ]
        for optionalURL in candidates {
            guard let url = optionalURL else { continue }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }
            urls.append(url)
        }
        return urls
    }

}
