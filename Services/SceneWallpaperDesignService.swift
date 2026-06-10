import Foundation
import CryptoKit

public struct SceneDynamicTextDesignOverride: Codable, Equatable, Sendable {
    public var hidden: Bool?
    public var textOverride: String?
    public var color: [Double]?
    public var alpha: Double?
    public var offsetX: Double?
    public var offsetY: Double?
    public var scaleMultiplier: Double?
    public var fontSizeMultiplier: Double?
    public var fontFamilyOverride: String?
    public var fontPathOverride: String?
    public var rotationOverride: Double?
    public var alignmentOverride: String?
    public var maxWidthOverride: Double?
    public var use24hFormat: Bool?
    public var showSeconds: Bool?
    public var delimiter: String?

    var isDefault: Bool {
        hidden == nil
            && textOverride == nil
            && color == nil
            && alpha == nil
            && offsetX == nil
            && offsetY == nil
            && scaleMultiplier == nil
            && fontSizeMultiplier == nil
            && fontFamilyOverride == nil
            && fontPathOverride == nil
            && rotationOverride == nil
            && alignmentOverride == nil
            && maxWidthOverride == nil
            && use24hFormat == nil
            && showSeconds == nil
            && delimiter == nil
    }
}

public struct SceneWallpaperDesignDocument: Codable, Equatable, Sendable {
    public var wallpaperPath: String
    public var overrides: [String: SceneDynamicTextDesignOverride]
}

public struct SceneDesignedDynamicTextEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let source: DynamicTextEntry
    public let hidden: Bool
    public let textOverride: String?
    public let colorOverride: [Double]?
    public let alphaOverride: Double?
    public let offsetX: Double
    public let offsetY: Double
    public let scaleMultiplier: Double
    public let fontSizeMultiplier: Double
    public let fontFamilyOverride: String?
    public let fontPathOverride: String?
    public let rotationOverride: Double?
    public let alignmentOverride: String?
    public let maxWidthOverride: Double?
    public let use24hFormat: Bool?
    public let showSeconds: Bool?
    public let delimiter: String?
}

public struct SceneDesignedDynamicTextInfo: Equatable, Sendable {
    public let base: WallpaperDynamicTextsInfo
    public let entries: [SceneDesignedDynamicTextEntry]
}

@MainActor
enum SceneWallpaperDesignService {
    private static let folderName = "SceneDesigns"

    static func wallpaperTitle(for wallpaperPath: String) -> String {
        let projectURL = URL(fileURLWithPath: wallpaperPath).appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return URL(fileURLWithPath: wallpaperPath).lastPathComponent
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func loadDocument(for wallpaperPath: String) -> SceneWallpaperDesignDocument {
        let fileURL = designFileURL(for: wallpaperPath)
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(SceneWallpaperDesignDocument.self, from: data) else {
            return SceneWallpaperDesignDocument(wallpaperPath: wallpaperPath, overrides: [:])
        }
        return decoded
    }

    static func saveDocument(_ document: SceneWallpaperDesignDocument, for wallpaperPath: String) throws {
        let fileURL = designFileURL(for: wallpaperPath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
    }

    static func resetDocument(for wallpaperPath: String) {
        let folderURL = designFileURL(for: wallpaperPath).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: folderURL)
    }

    static func resolveDesignedInfo(
        from info: WallpaperDynamicTextsInfo,
        wallpaperPath: String
    ) -> SceneDesignedDynamicTextInfo {
        let document = loadDocument(for: wallpaperPath)
        let entries = info.entries.map { entry in
            let override = document.overrides[entryDesignKey(entry)]
            let hidden: Bool
            if let overrideHidden = override?.hidden {
                hidden = overrideHidden
            } else {
                hidden = !entry.visible
            }
            return SceneDesignedDynamicTextEntry(
                id: entryDesignKey(entry),
                source: entry,
                hidden: hidden,
                textOverride: override?.textOverride,
                colorOverride: override?.color,
                alphaOverride: override?.alpha,
                offsetX: override?.offsetX ?? 0,
                offsetY: override?.offsetY ?? 0,
                scaleMultiplier: override?.scaleMultiplier ?? 1,
                fontSizeMultiplier: override?.fontSizeMultiplier ?? 1,
                fontFamilyOverride: override?.fontFamilyOverride,
                fontPathOverride: override?.fontPathOverride,
                rotationOverride: override?.rotationOverride,
                alignmentOverride: override?.alignmentOverride,
                maxWidthOverride: override?.maxWidthOverride,
                use24hFormat: override?.use24hFormat,
                showSeconds: override?.showSeconds,
                delimiter: override?.delimiter
            )
        }
        return SceneDesignedDynamicTextInfo(base: info, entries: entries)
    }

    static func mergeDesign(
        into info: WallpaperDynamicTextsInfo,
        wallpaperPath: String
    ) -> WallpaperDynamicTextsInfo {
        let designed = resolveDesignedInfo(from: info, wallpaperPath: wallpaperPath)
        let hiddenSourceIDs = Set(designed.entries.compactMap { entry -> String? in
            guard entry.hidden, let id = entry.source.id, !id.isEmpty else { return nil }
            return id
        })
        var mergedEntries: [DynamicTextEntry] = designed.entries.compactMap { designedEntry -> DynamicTextEntry? in
            if designedEntry.hidden {
                return nil
            }
            if let parentID = designedEntry.source.parentID, hiddenSourceIDs.contains(parentID) {
                return nil
            }

            var entry = designedEntry.source
            entry.visible = true
            if let textOverride = designedEntry.textOverride, !textOverride.isEmpty {
                entry.resolvedText = textOverride
            }
            entry.scriptPropertiesJSON = mergedScriptPropertiesJSON(
                baseJSON: entry.scriptPropertiesJSON,
                use24hFormat: designedEntry.use24hFormat,
                showSeconds: designedEntry.showSeconds,
                delimiter: designedEntry.delimiter
            )
            if let colorOverride = designedEntry.colorOverride, colorOverride.count >= 3 {
                entry.color = colorOverride
            }
            if let alphaOverride = designedEntry.alphaOverride {
                entry.alpha = alphaOverride
            }
            if designedEntry.offsetX != 0 {
                if let x = entry.finalOriginX ?? entry.originX ?? entry.finalX ?? entry.x {
                    entry.finalOriginX = x + designedEntry.offsetX
                }
            }
            if designedEntry.offsetY != 0 {
                if let y = entry.finalOriginY ?? entry.originY ?? entry.finalY ?? entry.y {
                    entry.finalOriginY = y + designedEntry.offsetY
                }
            }
            if designedEntry.scaleMultiplier != 1 {
                if let sx = entry.finalScaleX ?? entry.scaleX {
                    entry.finalScaleX = sx * designedEntry.scaleMultiplier
                }
                if let sy = entry.finalScaleY ?? entry.scaleY {
                    entry.finalScaleY = sy * designedEntry.scaleMultiplier
                }
            }
            if designedEntry.fontSizeMultiplier != 1 {
                if let fs = entry.effectiveFontSize ?? entry.fontSize {
                    entry.effectiveFontSize = fs * designedEntry.fontSizeMultiplier
                }
            }
            if let fontFamilyOverride = designedEntry.fontFamilyOverride, !fontFamilyOverride.isEmpty {
                entry.fontFamily = fontFamilyOverride
            }
            if let fontPathOverride = designedEntry.fontPathOverride, !fontPathOverride.isEmpty {
                entry.fontPath = fontPathOverride
            }
            if let rotationOverride = designedEntry.rotationOverride {
                entry.finalAngle = rotationOverride
                entry.rotation = rotationOverride
            }
            if let alignmentOverride = designedEntry.alignmentOverride, !alignmentOverride.isEmpty {
                entry.alignment = alignmentOverride
            }
            if let maxWidthOverride = designedEntry.maxWidthOverride, maxWidthOverride > 0 {
                entry.maxWidth = maxWidthOverride
            }
            return entry
        }
        applySelectedLanguageRuntimeText(to: &mergedEntries)
        return WallpaperDynamicTextsInfo(
            hasDynamicText: !mergedEntries.isEmpty,
            entries: mergedEntries,
            wallpaperPath: designed.base.wallpaperPath,
            sceneWidth: designed.base.sceneWidth,
            sceneHeight: designed.base.sceneHeight,
            extractedAt: designed.base.extractedAt
        )
    }

    private static func applySelectedLanguageRuntimeText(to entries: inout [DynamicTextEntry]) {
        guard let languageCode = entries.compactMap({ entry in
            languageCode(from: entry.name)
        }).first else { return }

        for index in entries.indices where isDateEntry(entries[index]) {
            entries[index].runtimeBehaviorOverride = "date"
            entries[index].runtimeLanguageCodeOverride = languageCode
        }
    }

    private static func isDateEntry(_ entry: DynamicTextEntry) -> Bool {
        let normalized = entry.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "date" || normalized.hasSuffix(" date")
    }

    private static func languageCode(from name: String) -> String? {
        let pattern = #"\(([A-Za-z]{2,8})\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: name, range: NSRange(name.startIndex..., in: name)).last,
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: name) else {
            return nil
        }
        return String(name[range]).uppercased()
    }

    static func entryDesignKey(_ entry: DynamicTextEntry) -> String {
        if let id = entry.id, !id.isEmpty {
            return "id:\(id)"
        }
        let renderOrder = entry.renderOrder.map(String.init) ?? "nil"
        return "name:\(entry.name)|order:\(renderOrder)"
    }

    private static func designFileURL(for wallpaperPath: String) -> URL {
        let root = designFolderURL(for: wallpaperPath)
        return root.appendingPathComponent("design.json")
    }

    private static func designFolderURL(for wallpaperPath: String) -> URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("WaifuX")
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(wallpaperHash(for: wallpaperPath), isDirectory: true)
    }

    private static func wallpaperHash(for wallpaperPath: String) -> String {
        let canonicalPath = URL(fileURLWithPath: wallpaperPath).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func mergedScriptPropertiesJSON(
        baseJSON: String?,
        use24hFormat: Bool?,
        showSeconds: Bool?,
        delimiter: String?
    ) -> String? {
        guard use24hFormat != nil || showSeconds != nil || delimiter != nil else {
            return baseJSON
        }

        var props: [String: Any] = [:]
        if let baseJSON,
           let data = baseJSON.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            props = decoded
        }

        if let use24hFormat {
            props["use24hFormat"] = use24hFormat
            props["_24"] = use24hFormat
        }
        if let showSeconds {
            props["showSeconds"] = showSeconds
        }
        if let delimiter {
            props["delimiter"] = delimiter
            props["addDelimiter"] = delimiter
        }

        guard JSONSerialization.isValidJSONObject(props),
              let data = try? JSONSerialization.data(withJSONObject: props, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return baseJSON
        }
        return json
    }
}
