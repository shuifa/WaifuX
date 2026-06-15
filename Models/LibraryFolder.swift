import Foundation

/// 库文件夹（支持壁纸和媒体两种内容类型）
struct LibraryFolder: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    let contentType: FolderContentType
    var parentFolderID: String?
    let createdAt: Date
    var updatedAt: Date
    /// 是否启用加密锁定（需要 Touch ID / 密码验证才能打开）
    var isLocked: Bool = false
    /// 文件夹所属集合（下载 / 收藏）
    var collection: FolderCollection

    init(
        id: String = UUID().uuidString,
        name: String,
        contentType: FolderContentType,
        parentFolderID: String? = nil,
        isLocked: Bool = false,
        collection: FolderCollection = .downloads
    ) {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.parentFolderID = parentFolderID
        self.isLocked = isLocked
        self.collection = collection
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    enum FolderContentType: String, Codable, Hashable {
        case wallpaper
        case media
    }

    enum FolderCollection: String, Codable, Hashable {
        case downloads
        case favorites
    }

    // MARK: - Codable（兼容旧数据：isLocked / collection 可能缺失）

    enum CodingKeys: String, CodingKey {
        case id, name, contentType, parentFolderID, createdAt, updatedAt, isLocked, collection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        contentType = try container.decode(FolderContentType.self, forKey: .contentType)
        parentFolderID = try container.decodeIfPresent(String.self, forKey: .parentFolderID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        // 兼容旧数据：没有 isLocked 字段时默认为 false
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        // 兼容旧数据：没有 collection 字段时默认为 downloads
        collection = try container.decodeIfPresent(FolderCollection.self, forKey: .collection) ?? .downloads
    }
}

// MARK: - 文件夹内项目（统一类型，用于 UI 展示）

enum LibraryItem: Identifiable, Hashable {
    case folder(LibraryFolder)
    case wallpaper(Wallpaper, downloadDate: Date?)
    case media(MediaItem, localFileURL: URL?)

    var id: String {
        switch self {
        case .folder(let folder): return "folder_\(folder.id)"
        case .wallpaper(let wallpaper, _): return wallpaper.id
        case .media(let media, _): return media.id
        }
    }

    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }

    var folder: LibraryFolder? {
        if case .folder(let f) = self { return f }
        return nil
    }

    var wallpaper: Wallpaper? {
        if case .wallpaper(let w, _) = self { return w }
        return nil
    }

    var mediaItem: MediaItem? {
        if case .media(let m, _) = self { return m }
        return nil
    }
}
