import Foundation
import CoreGraphics

/// crop 计算结果（全部归一化，原点左上，y 向下）。
struct CropLayout {
    /// 壁纸裁切框：把壁纸的 [origin, origin+size] 这段映射到可视框。
    var wallpaperCropRect: UnitRect
    /// 可视框在屏幕上的矩形（框外即 letterbox）。
    var viewportRect: UnitRect
    /// 框外填充色。
    var letterboxColor: CGColor
}

enum CropLayoutEngine {
    /// 输入壁纸原始像素尺寸、屏幕像素尺寸、crop 设置，输出归一化裁切框 + 可视框 + 黑边色。
    /// 纯函数，无副作用，可单测。
    static func compute(
        wallpaperSize: CGSize,
        screenSize: CGSize,
        settings: DisplayCropSettings
    ) -> CropLayout {
        let letterboxColor = Self.parseColorHex(settings.letterboxColorHex)

        // 不应裁切：回退现状（全屏 + 全图）。
        guard settings.shouldApplyCrop else {
            return CropLayout(
                wallpaperCropRect: .full,
                viewportRect: .full,
                letterboxColor: letterboxColor
            )
        }

        let targetAspect = settings.effectiveAspect ?? 1.0
        let screenAspect = (screenSize.height > 0)
            ? screenSize.width / screenSize.height
            : 1.0

        // 1. 算可视框 viewportRect（屏幕内居中放该比例的最大框）。
        let viewport: UnitRect
        if targetAspect > screenAspect {
            // 框更宽：框宽=1，框高=screenAspect/targetAspect，y 居中
            let h = screenAspect / targetAspect
            viewport = UnitRect(x: 0, y: (1 - h) / 2, w: 1, h: h)
        } else {
            // 框更窄/等：框高=1，框宽=targetAspect/screenAspect，x 居中
            let w = targetAspect / screenAspect
            viewport = UnitRect(x: (1 - w) / 2, y: 0, w: w, h: 1)
        }

        // 2. 算壁纸裁切框 wallpaperCropRect（可视框内 aspect-fill + pan/zoom）。
        // pan 约定：正值 = 看向该方向（正x=右→裁切框右移看到壁纸右侧；正y=下→看到壁纸下方）。
        let zoom = max(1.0, min(4.0, settings.zoom))
        let cropSize = 1.0 / zoom                  // zoom=1 裁全图；zoom=2 裁中央 1/2
        let panX = max(-1, min(1, settings.pan.x))
        let panY = max(-1, min(1, settings.pan.y))
        // 居中后按 pan 偏移；pan 作用域 = 当前 zoom 下可移动范围 (cropSize/2)。
        var originX = (0.5 - cropSize / 2) + panX * (cropSize / 2)
        var originY = (0.5 - cropSize / 2) + panY * (cropSize / 2)
        // clamp 到 [0, 1 - cropSize]
        let maxOrigin = 1.0 - cropSize
        originX = max(0, min(maxOrigin, originX))
        originY = max(0, min(maxOrigin, originY))

        return CropLayout(
            wallpaperCropRect: UnitRect(x: originX, y: originY, w: cropSize, h: cropSize),
            viewportRect: viewport,
            letterboxColor: letterboxColor
        )
    }

    /// 解析 #RRGGBB / RRGGBB → CGColor（alpha=1）。
    static func parseColorHex(_ hex: String) -> CGColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            return CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8) & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0
        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }
}
