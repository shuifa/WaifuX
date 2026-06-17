import Foundation

/// 场景配置覆盖键定义（对应 wallpaper-wgpu 的 __-prefixed 系统键）
public enum SceneConfigOverrideKey: String, CaseIterable, Sendable {
    // ── Camera ──
    case cameraZoom = "__camera_zoom"
    case cameraFov = "__camera_fov"
    case cameraNearz = "__camera_nearz"
    case cameraFarz = "__camera_farz"

    // ── Parallax ──
    case parallaxEnabled = "__parallax_enabled"
    case parallaxAmount = "__parallax_amount"
    case parallaxDelay = "__parallax_delay"
    case parallaxMouseInfluence = "__parallax_mouse_influence"

    // ── Display ──
    case orthoWidth = "__ortho_width"
    case orthoHeight = "__ortho_height"
    case textureReduction = "__texture_reduction"

    // ── Misc ──
    case clearEnabled = "__clear_enabled"
    case clearColor = "__clear_color"
    case cameraFade = "__camera_fade"

    // ── Lighting ──
    case ambientColor = "__ambient_color"
    case skylightColor = "__skylight_color"

    public var displayName: String {
        switch self {
        case .cameraZoom: return "缩放"
        case .cameraFov: return "视场角 (FOV)"
        case .cameraNearz: return "近裁剪面"
        case .cameraFarz: return "远裁剪面"
        case .parallaxEnabled: return "视差效果"
        case .parallaxAmount: return "视差强度"
        case .parallaxDelay: return "视差延迟"
        case .parallaxMouseInfluence: return "鼠标影响"
        case .orthoWidth: return "画布宽度"
        case .orthoHeight: return "画布高度"
        case .textureReduction: return "纹理质量缩减"
        case .clearEnabled: return "背景清除"
        case .clearColor: return "背景颜色"
        case .cameraFade: return "淡入效果"
        case .ambientColor: return "环境光颜色"
        case .skylightColor: return "天光颜色"
        }
    }

    public var displayNameEN: String {
        switch self {
        case .cameraZoom: return "Camera Zoom"
        case .cameraFov: return "FOV"
        case .cameraNearz: return "Near Z"
        case .cameraFarz: return "Far Z"
        case .parallaxEnabled: return "Parallax"
        case .parallaxAmount: return "Parallax Amount"
        case .parallaxDelay: return "Parallax Delay"
        case .parallaxMouseInfluence: return "Mouse Influence"
        case .orthoWidth: return "Canvas Width"
        case .orthoHeight: return "Canvas Height"
        case .textureReduction: return "Texture Reduction"
        case .clearEnabled: return "Clear Enabled"
        case .clearColor: return "Clear Color"
        case .cameraFade: return "Camera Fade"
        case .ambientColor: return "Ambient Color"
        case .skylightColor: return "Skylight Color"
        }
    }

    /// 是否为颜色类型（RGB 字符串）
    public var isColor: Bool {
        switch self {
        case .clearColor, .ambientColor, .skylightColor: return true
        default: return false
        }
    }

    /// 是否为布尔类型
    public var isBool: Bool {
        switch self {
        case .parallaxEnabled, .clearEnabled, .cameraFade: return true
        default: return false
        }
    }

    /// 默认值
    public var defaultValue: Double {
        switch self {
        case .cameraZoom: return 1.0
        case .cameraFov: return 50.0
        case .cameraNearz: return 0.01
        case .cameraFarz: return 10000.0
        case .parallaxAmount: return 0.5
        case .parallaxDelay: return 0.1
        case .parallaxMouseInfluence: return 0.07
        case .orthoWidth: return 1920.0
        case .orthoHeight: return 1080.0
        case .textureReduction: return 1.0
        default: return 0
        }
    }

    /// 滑块的取值范围
    public var sliderRange: ClosedRange<Double> {
        switch self {
        case .cameraZoom: return 0.1...5.0
        case .cameraFov: return 10.0...120.0
        case .cameraNearz: return 0.001...10.0
        case .cameraFarz: return 100.0...100000.0
        case .parallaxAmount: return 0.0...2.0
        case .parallaxDelay: return 0.0...1.0
        case .parallaxMouseInfluence: return 0.0...1.0
        case .orthoWidth: return 100.0...7680.0
        case .orthoHeight: return 100.0...4320.0
        case .textureReduction: return 1.0...8.0
        default: return 0...1
        }
    }
}

/// 场景壁纸 Scene Config 覆盖管理服务
///
/// 管理 wallpaper-wgpu 的 scene.json 内部参数覆盖。
/// 这些参数通过 `--user-properties` 的 `__` 前缀键传递，
/// 在 wallpaper-wgpu 端被 `apply_scene_config_overrides()` 解析并覆盖 SceneDescription 字段。
@MainActor
enum SceneConfigOverrideService {
    private static let defaultsKeyPrefix = "scene_config_overrides_v1_"

    // MARK: - 覆盖值加载/保存

    /// 加载指定壁纸的场景配置覆盖
    static func loadOverrides(for wallpaperPath: String) -> [SceneConfigOverrideKey: AnyCodableValue] {
        guard let data = UserDefaults.standard.data(forKey: storageKey(for: wallpaperPath)),
              let dict = try? JSONDecoder().decode([String: AnyCodableValue].self, from: data) else {
            return [:]
        }
        var result: [SceneConfigOverrideKey: AnyCodableValue] = [:]
        for (keyStr, value) in dict {
            if let key = SceneConfigOverrideKey(rawValue: keyStr) {
                result[key] = value
            }
        }
        return result
    }

    /// 保存指定壁纸的场景配置覆盖
    static func saveOverrides(_ overrides: [SceneConfigOverrideKey: AnyCodableValue], for wallpaperPath: String) {
        let dict = Dictionary(uniqueKeysWithValues: overrides.map { ($0.rawValue, $1) })
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: storageKey(for: wallpaperPath))
        }
    }

    /// 设置单个覆盖值
    static func setOverride(key: SceneConfigOverrideKey, value: AnyCodableValue, for wallpaperPath: String) {
        var overrides = loadOverrides(for: wallpaperPath)
        overrides[key] = value
        saveOverrides(overrides, for: wallpaperPath)
    }

    /// 重置单个覆盖
    static func resetOverride(key: SceneConfigOverrideKey, for wallpaperPath: String) {
        var overrides = loadOverrides(for: wallpaperPath)
        overrides.removeValue(forKey: key)
        saveOverrides(overrides, for: wallpaperPath)
    }

    /// 重置所有覆盖
    static func resetAllOverrides(for wallpaperPath: String) {
        UserDefaults.standard.removeObject(forKey: storageKey(for: wallpaperPath))
    }

    /// 是否有任何覆盖
    static func hasOverrides(for wallpaperPath: String) -> Bool {
        !loadOverrides(for: wallpaperPath).isEmpty
    }

    // MARK: - JSON 生成

    /// 生成用于 wallpaper-wgpu 的场景配置覆盖 JSON
    /// 格式: {"__camera_zoom": 1.5, "__parallax_enabled": "true", ...}
    static func propertiesOverrideJSON(for wallpaperPath: String) -> String? {
        let overrides = loadOverrides(for: wallpaperPath)
        guard !overrides.isEmpty else { return nil }

        let dict = overrides.mapValues { value -> Any in
            switch value {
            case .bool(let b): return b
            case .number(let n): return n
            case .string(let s): return s
            case .null: return NSNull()
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    // MARK: - 合并到现有 user-properties JSON

    /// 将场景配置覆盖合并到现有的 user-properties JSON 中
    static func mergedPropertiesJSON(userPropertiesJSON: String?, for wallpaperPath: String) -> String? {
        let sceneOverrides = loadOverrides(for: wallpaperPath)
        guard !sceneOverrides.isEmpty else { return userPropertiesJSON }

        // 解析现有 JSON
        var merged: [String: Any] = [:]
        if let existingJSON = userPropertiesJSON,
           let existingData = existingJSON.data(using: .utf8),
           let existingDict = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            merged = existingDict
        }

        // 合并场景配置覆盖
        for (key, value) in sceneOverrides {
            switch value {
            case .bool(let b): merged[key.rawValue] = b
            case .number(let n): merged[key.rawValue] = n
            case .string(let s): merged[key.rawValue] = s
            case .null: merged[key.rawValue] = NSNull()
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return userPropertiesJSON
        }
        return str
    }

    // MARK: - 辅助方法

    private static func storageKey(for wallpaperPath: String) -> String {
        let safeName = wallpaperPath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return defaultsKeyPrefix + safeName
    }
}
