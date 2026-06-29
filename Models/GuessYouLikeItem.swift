import SwiftUI

// MARK: - 猜你喜欢卡片数据模型

struct GuessYouLikeItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let imageURL: String
    let destination: String
    let contentType: ContentType
    let sourceName: String
    /// 预览视频 URL（DongTai / Wallsflow 预填充，避免详情页重复请求）
    let previewVideoURL: String?
    /// 下载选项（DongTai / Wallsflow 预填充）
    let downloadOptions: [MediaDownloadOption]

    /// 运行时生成的渐变色（不参与编解码）
    var gradientColors: [Color] {
        let palettes: [[Color]] = [
            [Color(hex: "7C3AED"), Color(hex: "C084FC"), Color(hex: "F472B6")],
            [Color(hex: "0EA5E9"), Color(hex: "38BDF8"), Color(hex: "7DD3FC")],
            [Color(hex: "F97316"), Color(hex: "FB923C"), Color(hex: "FBBF24")],
            [Color(hex: "1E1B4B"), Color(hex: "312E81"), Color(hex: "4338CA")],
            [Color(hex: "059669"), Color(hex: "34D399"), Color(hex: "6EE7B7")],
            [Color(hex: "DC2626"), Color(hex: "F97316"), Color(hex: "F59E0B")],
            [Color(hex: "4C1D95"), Color(hex: "6D28D9"), Color(hex: "8B5CF6")],
            [Color(hex: "0F766E"), Color(hex: "14B8A6"), Color(hex: "2DD4BF")],
            [Color(hex: "831843"), Color(hex: "BE185D"), Color(hex: "EC4899")],
            [Color(hex: "1E3A5F"), Color(hex: "1E4D8C"), Color(hex: "3B82F6")],
            [Color(hex: "365314"), Color(hex: "4D7C0F"), Color(hex: "65A30D")],
            [Color(hex: "7C2D12"), Color(hex: "9A3412"), Color(hex: "C2410C")],
        ]
        return palettes[abs(id.hashValue) % palettes.count]
    }

    init(id: String, title: String, subtitle: String, imageURL: String, destination: String, contentType: ContentType, sourceName: String, previewVideoURL: String? = nil, downloadOptions: [MediaDownloadOption] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.destination = destination
        self.contentType = contentType
        self.sourceName = sourceName
        self.previewVideoURL = previewVideoURL
        self.downloadOptions = downloadOptions
    }
}

// MARK: - Mock 数据（备用）

extension GuessYouLikeItem {
    static func mockItems() -> [GuessYouLikeItem] {
        (1...12).map { i in
            GuessYouLikeItem(
                id: "mock-\(i)",
                title: "推荐 \(i)",
                subtitle: "猜你喜欢",
                imageURL: "",
                destination: "https://example.com/\(i)",
                contentType: .wallpaper,
                sourceName: "Mock"
            )
        }
    }
}

// MARK: - Codable（用于缓存持久化）

extension GuessYouLikeItem: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, imageURL, destination, contentType, sourceName, previewVideoURL, downloadOptions
    }
}
