#!/usr/bin/env swift
import Foundation
import CoreGraphics

// 复制 CropLayoutEngine + 依赖类型的最小实现（与将改的源码一致）
struct UnitRect { var x: Double; var y: Double; var w: Double; var h: Double; static let full = UnitRect(x:0,y:0,w:1,h:1) }
struct DisplayCropSettings {
    var aspectPreset: AspectPreset = .autoFill
    var customAspect: Double? = nil
    var pan: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var zoom: Double = 1.0
    var letterboxColorHex: String = "000000"
    var isEnabled: Bool = true
    var effectiveAspect: Double? {
        switch aspectPreset { case .autoFill: return nil; case .custom: return customAspect; default: return aspectPreset.aspectRatio }
    }
    var shouldApplyCrop: Bool { isEnabled && effectiveAspect != nil }
}
enum AspectPreset: String { case autoFill, ratio16x9, ratio16x10, ratio21x9, ratio32x9, ratio4x3, ratio1x1, custom
    var aspectRatio: Double? {
        switch self { case .autoFill,.custom: return nil; case .ratio16x9: return 16.0/9; case .ratio16x10: return 16.0/10; case .ratio21x9: return 21.0/9; case .ratio32x9: return 32.0/9; case .ratio4x3: return 4.0/3; case .ratio1x1: return 1 }
    }
}

func compute(wallpaperSize: CGSize, screenSize: CGSize, settings: DisplayCropSettings) -> (viewport: UnitRect, crop: UnitRect) {
    guard settings.shouldApplyCrop else { return (.full, .full) }
    let targetAspect = settings.effectiveAspect ?? 1.0
    let screenAspect = screenSize.height > 0 ? screenSize.width/screenSize.height : 1.0
    let viewport: UnitRect
    if targetAspect > screenAspect {
        let h = screenAspect/targetAspect
        viewport = UnitRect(x: 0, y: (1-h)/2, w: 1, h: h)
    } else {
        let w = targetAspect/screenAspect
        viewport = UnitRect(x: (1-w)/2, y: 0, w: w, h: 1)
    }
    // === 新逻辑（将写入源码的部分）===
    let vpAspect = viewport.h > 0 ? viewport.w/viewport.h : 1.0
    let wpAspect = wallpaperSize.height > 0 ? wallpaperSize.width/wallpaperSize.height : 1.0
    let zoom = max(1.0, min(4.0, settings.zoom))
    let winW: Double, winH: Double
    if wpAspect > vpAspect {
        winH = 1.0/zoom; winW = winH * vpAspect
    } else {
        winW = 1.0/zoom; winH = winW / vpAspect
    }
    let panX = max(0, min(1, settings.pan.x))
    let panY = max(0, min(1, settings.pan.y))
    let originX = max(0, min(1-winW, panX - winW/2))
    let originY = max(0, min(1-winH, panY - winH/2))
    return (viewport, UnitRect(x: originX, y: originY, w: winW, h: winH))
}

func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a-b) < eps }
var pass = 0, fail = 0
func check(_ name: String, _ ok: Bool) { if ok { pass+=1; print("  ✓ \(name)") } else { fail+=1; print("  ✗ \(name)") } }

// 1) 32:9 预设 + 16:9 壁纸 + 16:9 屏 → 垂直可平移、水平铺满
// viewport: targetAspect=32/9 > screenAspect=16/9 → vp.h = (16/9)/(32/9) = 0.5, vp.w=1; vpAspect=2
// wpAspect=16/9 ≈ 1.778 < vpAspect=2 → else: winW=1, winH=1/2=0.5
do {
    var s = DisplayCropSettings(); s.aspectPreset = .ratio32x9; s.zoom = 1; s.pan = CGPoint(x: 0.5, y: 0.5)
    let (vp, crop) = compute(wallpaperSize: CGSize(width:1920,height:1080), screenSize: CGSize(width:1920,height:1080), settings: s)
    check("32:9 vp.h=0.5", approx(vp.h, 0.5))
    check("32:9 vp.w=1", approx(vp.w, 1.0))
    check("32:9 crop.w=1 (水平铺满)", approx(crop.w, 1.0))
    check("32:9 crop.h=0.5 (垂直富余)", approx(crop.h, 0.5))
    check("32:9 居中 crop.y=0.25", approx(crop.y, 0.25))
    // pan.y=0（看上方）→ originY = max(0, min(0.5, 0-0.25)) = 0
    var s2 = s; s2.pan = CGPoint(x:0.5, y:0)
    let c2 = compute(wallpaperSize: CGSize(width:1920,height:1080), screenSize: CGSize(width:1920,height:1080), settings: s2).crop
    check("32:9 pan.y=0 → crop.y=0 (看上方)", approx(c2.y, 0))
    // pan.y=1（看下方）→ originY = max(0, min(0.5, 1-0.25)) = 0.5
    var s3 = s; s3.pan = CGPoint(x:0.5, y:1)
    let c3 = compute(wallpaperSize: CGSize(width:1920,height:1080), screenSize: CGSize(width:1920,height:1080), settings: s3).crop
    check("32:9 pan.y=1 → crop.y=0.5 (看下方)", approx(c3.y, 0.5))
}

// 2) 1:1 预设 + 16:9 壁纸 + 16:9 屏 → 水平可平移、垂直铺满
// viewport: targetAspect=1 < screenAspect=16/9 → vp.w = 1/(16/9) = 9/16 = 0.5625, vp.h=1; vpAspect=9/16
// wpAspect=16/9 > vpAspect=9/16 → if: winH=1, winW=1*9/16=0.5625
do {
    var s = DisplayCropSettings(); s.aspectPreset = .ratio1x1; s.zoom = 1; s.pan = CGPoint(x:0.5, y:0.5)
    let (vp, crop) = compute(wallpaperSize: CGSize(width:1920,height:1080), screenSize: CGSize(width:1920,height:1080), settings: s)
    check("1:1 vp.w=0.5625", approx(vp.w, 9.0/16.0))
    check("1:1 vp.h=1", approx(vp.h, 1.0))
    check("1:1 crop.h=1 (垂直铺满)", approx(crop.h, 1.0))
    check("1:1 crop.w=0.5625 (水平富余)", approx(crop.w, 9.0/16.0))
    check("1:1 居中 crop.x=(1-0.5625)/2=0.21875", approx(crop.x, (1 - 9.0/16.0)/2))
    // pan.x=0 → originX = max(0, min(0.4375, 0-0.28125)) = 0
    var s2 = s; s2.pan = CGPoint(x:0, y:0.5)
    check("1:1 pan.x=0 → crop.x=0 (看左)", approx(compute(wallpaperSize: CGSize(width:1920,height:1080), screenSize: CGSize(width:1920,height:1080), settings: s2).crop.x, 0))
    // pan.x=1 → originX = max(0, min(0.4375, 1-0.28125)) = 0.4375
    var s3 = s; s3.pan = CGPoint(x:1, y:0.5)
    check("1:1 pan.x=1 → crop.x=0.4375 (看右)", approx(compute(wallpaperSize: CGSize(width:1920,height:1080), screenSize: CGSize(width:1920,height:1080), settings: s3).crop.x, 1 - 9.0/16.0))
}

// 3) 同比例（壁纸与可视框同 aspect）→ 无平移空间
// 16:9 预设在 16:9 屏 → vp = full(1,1)；wpAspect=16/9 > vpAspect=1 → if: winH=1, winW=1
do {
    var s = DisplayCropSettings(); s.aspectPreset = .ratio16x9; s.zoom = 1; s.pan = CGPoint(x:0.2, y:0.8)
    let (_, crop) = compute(wallpaperSize: CGSize(width:1920,height:1080), screenSize: CGSize(width:1920,height:1080), settings: s)
    check("同比例 crop=full", approx(crop.w,1) && approx(crop.h,1) && approx(crop.x,0) && approx(crop.y,0))
}

// 4) zoom=2 缩小窗口，平移范围变大
// 32:9 预设 16:9 屏 wpAspect=16/9 < vpAspect=2 → else: winW=1/2=0.5, winH=0.5/2=0.25
do {
    var s = DisplayCropSettings(); s.aspectPreset = .ratio32x9; s.zoom = 2; s.pan = CGPoint(x:0.5, y:0.5)
    let crop = compute(wallpaperSize: CGSize(width:1920,height:1080), screenSize: CGSize(width:1920,height:1080), settings: s).crop
    check("zoom=2 crop.w=0.5", approx(crop.w, 0.5))
    check("zoom=2 crop.h=0.25", approx(crop.h, 0.25))
}

// 5) clamp 不超界：pan 极端值窗口贴边
// 1:1 预设 vpAspect=9/16, wpAspect>vpAspect → if: winH=1, winW=0.5625
// pan.x=-5 → originX=0；pan.y=5 → originY=max(0, min(0, 5-0.5))=0 (winH=1 无垂直空间)
do {
    var s = DisplayCropSettings(); s.aspectPreset = .ratio1x1; s.zoom = 1; s.pan = CGPoint(x:-5, y:5)
    let crop = compute(wallpaperSize: CGSize(width:1920,height:1080), screenSize: CGSize(width:1920,height:1080), settings: s).crop
    check("clamp pan.x→0 crop.x=0", approx(crop.x, 0))
    check("clamp 1:1 无垂直空间 crop.y=0", approx(crop.y, 0))
}

// 6) clamp 32:9 垂直方向极值
do {
    var s = DisplayCropSettings(); s.aspectPreset = .ratio32x9; s.zoom = 1; s.pan = CGPoint(x:0.5, y:-3)
    let crop = compute(wallpaperSize: CGSize(width:1920,height:1080), screenSize: CGSize(width:1920,height:1080), settings: s).crop
    check("clamp 32:9 pan.y=-3 → crop.y=0", approx(crop.y, 0))
}

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
