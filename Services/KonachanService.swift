import Foundation

// MARK: - Konachan 壁纸数据源服务
///
/// Konachan (https://konachan.com/) 是一个以 ACG / 二次元插画壁纸为主的 Moebooru 系站点。
/// 本 Service 负责：
///   1. 调用 Konachan JSON API (post.json / tag.json) 获取数据
///   2. 将 KonachanPost 映射为标准 Wallpaper 模型
///   3. 提供标签建议接口
///
/// API 参考: https://konachan.com/help/api
actor KonachanService {
    static let shared = KonachanService()

    private let networkService = NetworkService.shared

    /// 基础 URL
    private let baseURL = "https://konachan.com"

    /// 请求限速：两次请求之间至少间隔的时间
    private let minimumRequestInterval: TimeInterval = 0.5
    private var lastRequestTime: Date = .distantPast

    // MARK: - 公开 API

    /// 搜索壁纸
    /// - Parameters:
    ///   - query: 搜索关键词（标签）
    ///   - page: 页码，从 1 开始
    ///   - perPage: 每页数量，最大 100
    ///   - purity: 内容分级选择
    ///   - sorting: 排序方式
    /// - Returns: 标准 WallpaperSearchResponse
    func search(
        query: String = "",
        page: Int = 1,
        perPage: Int = 24,
        purity: KonachanPuritySelection = .safeOnly,
        sorting: KonachanSorting = .dateAdded
    ) async throws -> WallpaperSearchResponse {
        // 构造 tags 参数
        var tags: [String] = []

        // 添加用户查询
        if !query.isEmpty {
            tags.append(query)
        }

        // 添加 purity 筛选
        let purityTags = purity.ratingTags
        if purityTags.count == 1 {
            // 单个 rating 直接添加
            tags.append(contentsOf: purityTags)
        } else if purityTags.count > 1 {
            // 多个 rating: Moebooru 标签是 AND 语义，rating:s rating:q 可能无结果
            // 保守策略：取第一个 rating 或使用默认 safe
            tags.append("rating:s")
        }

        // 添加排序
        if sorting.requiresOrderTag {
            tags.append(sorting.orderTag)
        }

        let tagsParam = tags.joined(separator: " ")

        let urlString = "\(baseURL)/post.json?limit=\(perPage)&page=\(page)&tags=\(tagsParam.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"

        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidResponse
        }

        // 限速
        await enforceRateLimit()

        let posts: [KonachanPost] = try await fetchWithFallback(
            [KonachanPost].self,
            from: url
        )

        // 映射为 Wallpaper
        let wallpapers = posts.map { $0.toWallpaper() }

        // 构造 Meta 信息
        // Konachan 不返回总数，根据返回数量判断是否有更多页
        let hasMore = posts.count >= perPage
        let estimatedLastPage = hasMore ? page + 10 : page
        let estimatedTotal = hasMore ? page * perPage + perPage : wallpapers.count

        let meta = WallpaperSearchResponse.Meta(
            query: query.isEmpty ? nil : query,
            currentPage: page,
            perPage: .int(perPage),
            total: estimatedTotal,
            lastPage: estimatedLastPage,
            seed: nil
        )

        return WallpaperSearchResponse(meta: meta, data: wallpapers)
    }

    /// 获取热门/精选壁纸（高分排序）
    func fetchFeatured(limit: Int = 24) async throws -> [Wallpaper] {
        let response = try await search(
            page: 1,
            perPage: limit,
            purity: .safeOnly,
            sorting: .score
        )
        return response.data
    }

    /// 获取最新壁纸
    func fetchLatest(limit: Int = 8) async throws -> [Wallpaper] {
        let response = try await search(
            page: 1,
            perPage: limit,
            purity: .safeOnly,
            sorting: .dateAdded
        )
        return response.data
    }

    /// 获取 Top 壁纸
    func fetchTop(limit: Int = 8) async throws -> [Wallpaper] {
        let response = try await search(
            page: 1,
            perPage: limit,
            purity: .safeOnly,
            sorting: .score
        )
        return Array(response.data.prefix(limit))
    }

    /// 标签建议
    /// - Parameters:
    ///   - query: 标签前缀
    ///   - limit: 返回数量
    /// - Returns: 匹配的标签列表
    func suggestTags(query: String, limit: Int = 10) async throws -> [KonachanTag] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "\(baseURL)/tag.json?limit=\(limit)&page=1&name=\(encoded)"

        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidResponse
        }

        await enforceRateLimit()

        let tags: [KonachanTag] = try await fetchWithFallback(
            [KonachanTag].self,
            from: url
        )

        // 按 count 降序排序，热门标签在前
        return tags.sorted { $0.count > $1.count }
    }

    // MARK: - Private

    /// 默认请求头 — 使用真实 Safari UA + Referer 避免 403
    /// Konachan 对缺少 Referer 或非浏览器 UA 的请求可能返回 403。
    private var defaultHeaders: [String: String] {
        [
            "Accept": "application/json, text/plain, */*",
            "Accept-Encoding": "gzip, deflate",
            "Accept-Language": "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7,ja;q=0.6",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15",
            "Referer": "https://konachan.com/",
            "Origin": "https://konachan.com",
            "Connection": "keep-alive",
            "DNT": "1"
        ]
    }

    /// 当标准请求头返回 403 时的备用请求头（更简化的伪装）
    private var fallbackHeaders: [String: String] {
        [
            "Accept": "application/json",
            "User-Agent": "WaifuX/\(appVersion) (macOS; https://github.com/...)",
            "Referer": "https://konachan.com/"
        ]
    }

    /// App 版本号
    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    /// 限速控制：保证两次请求之间至少有 minimumRequestInterval 间隔
    private func enforceRateLimit() async {
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        if elapsed < minimumRequestInterval {
            let delay = minimumRequestInterval - elapsed
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        lastRequestTime = Date()
    }

    /// 带伪装和回退的请求方法：先使用浏览器伪装请求，403 时换简化头重试
    private func fetchWithFallback<T: Decodable & Sendable>(
        _ type: T.Type,
        from url: URL
    ) async throws -> T {
        do {
            return try await networkService.fetch(
                T.self,
                from: url,
                headers: defaultHeaders
            )
        } catch let error as NetworkError {
            if case .httpError(403) = error {
                // 403 时使用备用头重试一次
                print("[KonachanService] 403 received, retrying with fallback headers...")
                return try await networkService.fetch(
                    T.self,
                    from: url,
                    headers: fallbackHeaders
                )
            }
            throw error
        }
    }
}

// MARK: - Konachan 预设热门标签

extension KonachanService {
    /// 预设热门标签（适用于 Konachan 源探索页展示）
    /// 按主题分类，用户可直接点击搜索
    struct PresetTag: Identifiable, Hashable {
        let id: String
        let name: String
        /// 发送给 API 的完整查询字符串
        let query: String
    }

    /// 预设热门标签列表
    static let presetTags: [PresetTag] = [
        // 作品
        PresetTag(id: "genshin", name: "原神", query: "genshin_impact"),
        PresetTag(id: "honkai3", name: "崩坏3", query: "honkai_impact_3rd"),
        PresetTag(id: "hsr", name: "崩坏：星穹铁道", query: "honkai_star_rail"),
        PresetTag(id: "zzz", name: "绝区零", query: "zenless_zone_zero"),
        PresetTag(id: "fgo", name: "Fate/Grand Order", query: "fate_grand_order"),
        PresetTag(id: "blue_archive", name: "蔚蓝档案", query: "blue_archive"),
        PresetTag(id: "gfl", name: "少女前线", query: "girls_frontline"),
        PresetTag(id: "azur_lane", name: "碧蓝航线", query: "azur_lane"),
        PresetTag(id: "nikke", name: "NIKKE", query: "nikke"),
        PresetTag(id: "vocaloid", name: "VOCALOID", query: "vocaloid"),
        PresetTag(id: "touhou", name: "东方Project", query: "touhou"),
        // 风格
        PresetTag(id: "landscape", name: "风景", query: "landscape"),
        PresetTag(id: "sunset", name: "夕阳", query: "sunset"),
        PresetTag(id: "night", name: "夜景", query: "night"),
        PresetTag(id: "water", name: "水", query: "water"),
        PresetTag(id: "sky", name: "天空", query: "sky"),
        PresetTag(id: "clouds", name: "云", query: "clouds"),
        PresetTag(id: "flower", name: "花", query: "flower"),
        PresetTag(id: "stars", name: "星空", query: "stars"),
        PresetTag(id: "city", name: "城市", query: "cityscape"),
        // 角色特征
        PresetTag(id: "1girl", name: "单人少女", query: "1girl"),
        PresetTag(id: "1boy", name: "单人少年", query: "1boy"),
        PresetTag(id: "long_hair", name: "长发", query: "long_hair"),
        PresetTag(id: "short_hair", name: "短发", query: "short_hair"),
        PresetTag(id: "blonde", name: "金发", query: "blonde_hair"),
        PresetTag(id: "blue_eyes", name: "蓝瞳", query: "blue_eyes"),
        PresetTag(id: "glasses", name: "眼镜", query: "glasses"),
        PresetTag(id: "uniform", name: "制服", query: "school_uniform"),
        PresetTag(id: "swimsuit", name: "泳装", query: "swimsuit"),
        PresetTag(id: "maid", name: "女仆", query: "maid"),
        PresetTag(id: "witch", name: "魔女", query: "witch"),
        // 场景/情绪
        PresetTag(id: "smile", name: "微笑", query: "smile"),
        PresetTag(id: "sad", name: "悲伤", query: "sad"),
        PresetTag(id: "rain", name: "雨", query: "rain"),
        PresetTag(id: "snow", name: "雪", query: "snow"),
        PresetTag(id: "cherry_blossoms", name: "樱花", query: "cherry_blossoms"),
        PresetTag(id: "beach", name: "海滩", query: "beach"),
        PresetTag(id: "fantasy", name: "幻想", query: "fantasy"),
        PresetTag(id: "cyberpunk", name: "赛博朋克", query: "cyberpunk"),
    ]
}
