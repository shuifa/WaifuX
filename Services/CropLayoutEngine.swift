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

        // 2. 算壁纸裁切框 wallpaperCropRect（可视窗口在壁纸归一化空间内滑动）。
        // 窗口宽高比 = 可视框宽高比（保证壁纸铺进可视框不变形）；窗口尺寸由 zoom 缩放；
        // 平移范围 = 壁纸减窗口的真实富余量，clamp 在壁纸内（不超界、不露额外黑边）。
        // pan ∈ [0,1]，0.5=居中，= 可视窗口中心在壁纸上的归一化位置（0=壁纸左/上边，1=右/下边）。
        let vpAspect = viewport.h > 0 ? viewport.w / viewport.h : 1.0
        let wpAspect = (wallpaperSize.height > 0) ? wallpaperSize.width / wallpaperSize.height : 1.0
        let zoom = max(1.0, min(4.0, settings.zoom))
        let winW: Double, winH: Double
        if wpAspect > vpAspect {
            // 壁纸更宽 → 窗口高度贴满壁纸高度，宽度 = 高度 × vpAspect（水平有富余）
            winH = 1.0 / zoom
            winW = winH * vpAspect
        } else {
            // 壁纸更窄/等高 → 窗口宽度贴满壁纸宽度，高度 = 宽度 / vpAspect（垂直有富余）
            winW = 1.0 / zoom
            winH = winW / vpAspect
        }
        let panX = max(0, min(1, settings.pan.x))
        let panY = max(0, min(1, settings.pan.y))
        // origin = 中心 - 半窗；clamp 到 [0, 1-win] 保证窗口始终在壁纸内
        let originX = max(0, min(1 - winW, panX - winW / 2))
        let originY = max(0, min(1 - winH, panY - winH / 2))

        return CropLayout(
            wallpaperCropRect: UnitRect(x: originX, y: originY, w: winW, h: winH),
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
