import Foundation

/// 单个用户属性的完整信息
public struct SceneWallpaperProperty: Codable, Equatable, Sendable {
    public let key: String
    public let type: String
    public let text: String?
    public let originalValue: AnyCodableValue
    public var currentValue: AnyCodableValue
    public let options: [String: String]?
    public let min: Double?
    public let max: Double?
    public let step: Double?

    public var isModified: Bool {
        originalValue != currentValue
    }
}

/// 可编码的 Any 值（支持 Bool、Number、String）
public enum AnyCodableValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String {
        switch self {
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
        case .string(let s): return s
        case .null: return ""
        }
    }

    public var jsonValue: Any {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .null: return NSNull()
        }
    }
}

/// 场景壁纸属性文档（持久化用户覆盖值）
public struct SceneWallpaperPropertiesDocument: Codable, Equatable, Sendable {
    public let wallpaperPath: String
    public var overrides: [String: AnyCodableValue]
    public let backupDate: Date

    public init(wallpaperPath: String, overrides: [String: AnyCodableValue] = [:]) {
        self.wallpaperPath = wallpaperPath
        self.overrides = overrides
        self.backupDate = Date()
    }
}

/// 场景壁纸属性管理服务
///
/// 负责：
/// 1. 从 project.json 加载壁纸的用户属性定义和原始值
/// 2. 持久化用户的属性覆盖值
/// 3. 备份原始属性用于重置
/// 4. 生成 wallpaper-wgpu 所需的属性 JSON
@MainActor
enum SceneWallpaperPropertiesService {
    private static let folderName = "SceneProperties"

    // MARK: - 属性加载

    /// 从 project.json 加载所有用户属性定义
    static func loadProperties(for wallpaperPath: String) -> [SceneWallpaperProperty] {
        let contentDir = resolveContentDir(for: wallpaperPath)
        let projectURL = contentDir.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return parseProperties(from: json, wallpaperPath: wallpaperPath)
    }

    /// 获取用户覆盖后的属性列表（合并原始值和覆盖值）
    static func loadPropertiesWithOverrides(for wallpaperPath: String) -> [SceneWallpaperProperty] {
        let originalProps = loadProperties(for: wallpaperPath)
        let doc = loadDocument(for: wallpaperPath)
        guard !doc.overrides.isEmpty else { return originalProps }

        return originalProps.map { prop in
            var modified = prop
            if let override = doc.overrides[prop.key] {
                modified.currentValue = override
            }
            return modified
        }
    }

    // MARK: - 属性修改

    /// 修改单个属性值
    static func setProperty(key: String, value: AnyCodableValue, for wallpaperPath: String) throws {
        var doc = loadDocument(for: wallpaperPath)
        doc.overrides[key] = value
        try saveDocument(doc, for: wallpaperPath)
    }

    /// 批量修改属性
    static func setProperties(_ changes: [String: AnyCodableValue], for wallpaperPath: String) throws {
        var doc = loadDocument(for: wallpaperPath)
        for (key, value) in changes {
            doc.overrides[key] = value
        }
        try saveDocument(doc, for: wallpaperPath)
    }

    /// 重置单个属性为原始值
    static func resetProperty(key: String, for wallpaperPath: String) throws {
        var doc = loadDocument(for: wallpaperPath)
        doc.overrides.removeValue(forKey: key)
        try saveDocument(doc, for: wallpaperPath)
    }

    /// 重置所有属性为原始值
    static func resetAllProperties(for wallpaperPath: String) throws {
        let doc = SceneWallpaperPropertiesDocument(wallpaperPath: wallpaperPath)
        try saveDocument(doc, for: wallpaperPath)
    }

    /// 检查是否有任何属性被修改
    static func hasModifiedProperties(for wallpaperPath: String) -> Bool {
        let doc = loadDocument(for: wallpaperPath)
        return !doc.overrides.isEmpty
    }

    // MARK: - 属性 JSON 生成

    /// 生成用于 wallpaper-wgpu 的属性覆盖 JSON 字符串
    /// 格式: {"prop_key": "value", ...}
    static func propertiesOverrideJSON(for wallpaperPath: String) -> String? {
        let doc = loadDocument(for: wallpaperPath)
        guard !doc.overrides.isEmpty else { return nil }

        let dict = doc.overrides.mapValues { $0.stringValue }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    /// 生成完整的属性参数列表（用于 wallpaper-wgpu CLI）
    /// 返回 ["--user-properties", "{json}"] 或空数组
    static func cliArguments(for wallpaperPath: String) -> [String] {
        guard let json = propertiesOverrideJSON(for: wallpaperPath) else { return [] }
        return ["--user-properties", json]
    }

    // MARK: - 持久化

    static func loadDocument(for wallpaperPath: String) -> SceneWallpaperPropertiesDocument {
        let fileURL = documentFileURL(for: wallpaperPath)
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(SceneWallpaperPropertiesDocument.self, from: data) else {
            return SceneWallpaperPropertiesDocument(wallpaperPath: wallpaperPath)
        }
        return decoded
    }

    private static func saveDocument(_ document: SceneWallpaperPropertiesDocument, for wallpaperPath: String) throws {
        let fileURL = documentFileURL(for: wallpaperPath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func documentFileURL(for wallpaperPath: String) -> URL {
        let safeName = wallpaperPath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.waifux.WaifuX", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        return baseDir.appendingPathComponent("\(safeName).json")
    }

    // MARK: - 解析

    private static func resolveContentDir(for wallpaperPath: String) -> URL {
        let url = URL(fileURLWithPath: wallpaperPath)
        if url.pathExtension.lowercased() == "pkg" {
            // 对于 .pkg 文件，需要先解包
            if let extracted = extractPKGIfNeeded(at: url) {
                return extracted
            }
        }
        return WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
    }

    private static func extractPKGIfNeeded(at url: URL) -> URL? {
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wallpaperengine_props_\(url.deletingPathExtension().lastPathComponent)_\(UUID().uuidString.prefix(8))")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", url.path, "-d", tempDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? tempDir : nil
        } catch {
            return nil
        }
    }

    private static func parseProperties(from json: [String: Any], wallpaperPath: String) -> [SceneWallpaperProperty] {
        guard let general = json["general"] as? [String: Any],
              let properties = general["properties"] as? [String: [String: Any]] else {
            return []
        }

        var result: [SceneWallpaperProperty] = []
        for (key, prop) in properties {
            let type = prop["type"] as? String ?? "text"
            let text = prop["text"] as? String
            let options = prop["options"] as? [String: String]
            let min = prop["min"] as? Double
            let max = prop["max"] as? Double
            let step = prop["step"] as? Double

            let value = parseAnyCodableValue(prop["value"])
            guard value != .null else { continue }

            let sceneProp = SceneWallpaperProperty(
                key: key,
                type: type,
                text: text,
                originalValue: value,
                currentValue: value,
                options: options,
                min: min,
                max: max,
                step: step
            )
            result.append(sceneProp)
        }

        return result.sorted { $0.key < $1.key }
    }

    private static func parseAnyCodableValue(_ any: Any?) -> AnyCodableValue {
        guard let any else { return .null }
        if let b = any as? Bool {
            return .bool(b)
        } else if let n = any as? NSNumber {
            // NSNumber 可以是 Bool 或 Number，需要区分
            if type(of: any) == type(of: NSNumber(value: true)) {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        } else if let s = any as? String {
            return .string(s)
        }
        return .null
    }
}
