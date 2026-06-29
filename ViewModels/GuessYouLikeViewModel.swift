import SwiftUI

// MARK: - 猜你喜欢 ViewModel

@MainActor
final class GuessYouLikeViewModel: ObservableObject {
    @Published var isShowing: Bool = false
    @Published var items: [GuessYouLikeItem] = []
    @Published var dealingProgress: Double = 0.0 // 0.0 → 1.0

    private var hasPreloaded = false
    /// 预加载 Task 引用，避免 show() 重复发起网络请求
    private var preloadTask: Task<Void, Never>?

    /// 后台预加载推荐数据（不展示 UI），应在 App 启动后的适当时机调用一次
    func preload() {
        guard !hasPreloaded else { return }
        hasPreloaded = true

        preloadTask = Task { @MainActor in
            let recommendations = await GuessYouLikeService.shared.getRecommendations()
            guard !Task.isCancelled else { return }
            if !recommendations.isEmpty {
                items = recommendations
            }
            preloadTask = nil
        }
    }

    /// 强制刷新推荐数据（忽略缓存）
    func refreshInBackground() {
        preloadTask?.cancel()
        preloadTask = Task { @MainActor in
            let recommendations = await GuessYouLikeService.shared.forceRefresh()
            guard !Task.isCancelled else { return }
            if !recommendations.isEmpty {
                items = recommendations
            }
            preloadTask = nil
        }
    }

    func show() {
        dealingProgress = 0.0
        isShowing = true

        // 每次点击都重新拉取推荐数据，保证结果不同
        preloadTask?.cancel()
        preloadTask = Task { @MainActor in
            var recommendations = await GuessYouLikeService.shared.forceRefresh()
            if recommendations.isEmpty {
                print("[GYL] Service returned empty, retrying with fresh fetch")
                recommendations = await GuessYouLikeService.shared.forceRefresh()
            }
            if recommendations.isEmpty {
                print("[GYL] Still empty after retry, using mock data")
                recommendations = GuessYouLikeItem.mockItems()
            }
            guard !Task.isCancelled else { return }
            items = recommendations
            try? await Task.sleep(nanoseconds: 200_000_000)
            dealingProgress = 1.0
            preloadTask = nil
        }
    }

    func dismiss() {
        withAnimation(.easeOut(duration: 0.25)) {
            isShowing = false
            dealingProgress = 0.0
        }
    }

    /// 根据卡片索引获取延迟后的进度（用于顺序发牌）
    func dealingDelay(for index: Int) -> Double {
        Double(index) * 0.08
    }
}
