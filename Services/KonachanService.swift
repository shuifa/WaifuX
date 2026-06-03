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

// MARK: - Konachan 分类与热门标签

extension KonachanService {
    /// 分类标签（类似 4K 的分类，按作品/风格分类）
    struct KonachanCategory: Identifiable, Hashable {
        let id: String
        let name: String
        /// 发送给 API 的查询字符串
        let query: String

        /// SF Symbol 图标名
        var icon: String {
            switch id {
            case "genshin": return "sparkles"
            case "hsr": return "star.fill"
            case "zzz": return "bolt.fill"
            case "fgo": return "shield.fill"
            case "touhou": return "cloud.fill"
            case "blue_archive": return "book.fill"
            case "azur_lane": return "anchor.fill"
            case "vocaloid": return "music.mic"
            case "landscape": return "mountain.2.fill"
            case "cyberpunk": return "cpu.fill"
            default: return "square.grid.2x2.fill"
            }
        }

        /// 渐变强调色
        var accentColors: [String] {
            switch id {
            case "genshin": return ["4FC3F7", "29B6F6"]
            case "hsr": return ["CE93D8", "AB47BC"]
            case "zzz": return ["FFE082", "FFA726"]
            case "fgo": return ["EF5350", "C62828"]
            case "touhou": return ["81D4FA", "4FC3F7"]
            case "blue_archive": return ["81C784", "388E3C"]
            case "azur_lane": return ["64B5F6", "1976D2"]
            case "vocaloid": return ["F06292", "EC407A"]
            case "landscape": return ["A5D6A7", "43A047"]
            case "cyberpunk": return ["FF8A65", "E64A19"]
            default: return ["FF9B58", "F54E42"]
            }
        }
    }

    /// 分类列表（≈ 10 个，类似 4K 源的分类）
    static let categories: [KonachanCategory] = [
        KonachanCategory(id: "genshin", name: "原神", query: "genshin_impact"),
        KonachanCategory(id: "hsr", name: "星穹铁道", query: "honkai_star_rail"),
        KonachanCategory(id: "zzz", name: "绝区零", query: "zenless_zone_zero"),
        KonachanCategory(id: "fgo", name: "Fate", query: "fate_grand_order"),
        KonachanCategory(id: "touhou", name: "东方", query: "touhou"),
        KonachanCategory(id: "blue_archive", name: "蔚蓝档案", query: "blue_archive"),
        KonachanCategory(id: "azur_lane", name: "碧蓝航线", query: "azur_lane"),
        KonachanCategory(id: "vocaloid", name: "VOCALOID", query: "vocaloid"),
        KonachanCategory(id: "landscape", name: "风景", query: "landscape"),
        KonachanCategory(id: "cyberpunk", name: "赛博朋克", query: "cyberpunk"),
    ]

    /// 热门标签（仅少数，不换行展示）
    struct HotTag: Identifiable, Hashable {
        let id: String
        let name: String
        let query: String
    }

    static let hotTags: [HotTag] = [
        HotTag(id: "1girl", name: "少女", query: "1girl"),
        HotTag(id: "long_hair", name: "长发", query: "long_hair"),
        HotTag(id: "uniform", name: "制服", query: "school_uniform"),
        HotTag(id: "swimsuit", name: "泳装", query: "swimsuit"),
        HotTag(id: "glasses", name: "眼镜", query: "glasses"),
        HotTag(id: "smile", name: "微笑", query: "smile"),
    ]
}
