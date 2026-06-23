import XCTest
@testable import WaifuX

final class CropLayoutEngineTests: XCTestCase {

    private func assertRect(_ actual: UnitRect, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ file: StaticString = #filePath, _ line: UInt = #line) {
        XCTAssertEqual(actual.x, x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.y, y, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.w, w, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.h, h, accuracy: 1e-9, file: file, line: line)
    }

    func testAutoFillReturnsFullScreenAndFullCrop() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .autoFill
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 3440, height: 1440),
            settings: s)
        assertRect(layout.viewportRect, 0, 0, 1, 1)
        assertRect(layout.wallpaperCropRect, 0, 0, 1, 1)
    }

    func testDisabledReturnsFullScreenAndFullCrop() {
        var s = DisplayCropSettings.defaultSettings
        s.isEnabled = false
        s.aspectPreset = .ratio16x9
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 3440, height: 1440),
            settings: s)
        assertRect(layout.viewportRect, 0, 0, 1, 1)
        assertRect(layout.wallpaperCropRect, 0, 0, 1, 1)
    }

    /// 21:9 壁纸在 21:9 屏选 21:9 预设 → 可视框=全屏，壁纸铺满无黑边。
    func testSameAspectAsScreenViewportIsFullScreen() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio21x9
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 2560, height: 1080),
            screenSize: CGSize(width: 3360, height: 1440),  // 屏精确 21:9 (3360/1440 = 21/9)
            settings: s)
        assertRect(layout.viewportRect, 0, 0, 1, 1)
        assertRect(layout.wallpaperCropRect, 0, 0, 1, 1)
    }

    /// 16:9 预设在 16:9 屏 → 可视框=全屏；壁纸 16:9 铺满框，裁切框=full。
    func testSixteenNineOnSixteenNineScreen() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio16x9
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 1920, height: 1080),
            settings: s)
        assertRect(layout.viewportRect, 0, 0, 1, 1)
        assertRect(layout.wallpaperCropRect, 0, 0, 1, 1)
    }

    /// 16:9 预设在 21:9 屏（屏更宽）→ 框高=1，框宽=screenAspect/targetAspect，左右黑边。
    func testSixteenNineOnUltrawideLetterboxLeftRight() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio16x9
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 3440, height: 1440),
            settings: s)
        let expectedW = (16.0/9.0) / (3440.0/1440.0)
        XCTAssertEqual(layout.viewportRect.y, 0, accuracy: 1e-9)
        XCTAssertEqual(layout.viewportRect.h, 1, accuracy: 1e-9)
        XCTAssertEqual(layout.viewportRect.w, expectedW, accuracy: 1e-6)
        XCTAssertEqual(layout.viewportRect.x, (1 - expectedW) / 2, accuracy: 1e-6)
        assertRect(layout.wallpaperCropRect, 0, 0, 1, 1)
    }

    /// 21:9 预设在 16:9 屏（屏更窄）→ 框宽=1，框高=screenAspect/targetAspect，上下黑边。
    func testUltrawideOnSixteenNineLetterboxTopBottom() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio21x9
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 2560, height: 1080),
            screenSize: CGSize(width: 1920, height: 1080),
            settings: s)
        let expectedH = (1920.0/1080.0) / (21.0/9.0)
        XCTAssertEqual(layout.viewportRect.x, 0, accuracy: 1e-9)
        XCTAssertEqual(layout.viewportRect.w, 1, accuracy: 1e-9)
        XCTAssertEqual(layout.viewportRect.h, expectedH, accuracy: 1e-6)
        XCTAssertEqual(layout.viewportRect.y, (1 - expectedH) / 2, accuracy: 1e-6)
    }

    /// zoom=2 → 裁切框尺寸 = 1/2，居中。
    func testZoomHalvesCropSize() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio16x9
        s.zoom = 2.0
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 1920, height: 1080),
            settings: s)
        assertRect(layout.wallpaperCropRect, 0.25, 0.25, 0.5, 0.5)
    }

    /// pan=1（右移到底）+ zoom=2 → 裁切框 x=0.5（clamp 到右边缘）。
    func testPanRightShiftsCropLeft() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio16x9
        s.zoom = 2.0
        s.pan = CGPoint(x: 1, y: 0)
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 1920, height: 1080),
            settings: s)
        XCTAssertEqual(layout.wallpaperCropRect.w, 0.5, accuracy: 1e-9)
        XCTAssertEqual(layout.wallpaperCropRect.x, 0.5, accuracy: 1e-9)
    }

    /// pan 超过 1 应被 clamp 到裁切框范围。
    func testPanClampsToEdges() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio16x9
        s.zoom = 2.0
        s.pan = CGPoint(x: 5, y: 5)
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 1920, height: 1080),
            settings: s)
        XCTAssertEqual(layout.wallpaperCropRect.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(layout.wallpaperCropRect.y, 0.5, accuracy: 1e-9)
    }

    /// zoom 下限 1.0、上限 4.0。
    func testZoomClampsToRange() {
        var sLow = DisplayCropSettings.defaultSettings
        sLow.aspectPreset = .ratio16x9
        sLow.zoom = 0.2
        let lLow = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 1920, height: 1080),
            settings: sLow)
        XCTAssertEqual(lLow.wallpaperCropRect.w, 1, accuracy: 1e-9)

        var sHigh = DisplayCropSettings.defaultSettings
        sHigh.aspectPreset = .ratio16x9
        sHigh.zoom = 10
        let lHigh = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 1920, height: 1080),
            settings: sHigh)
        XCTAssertEqual(lHigh.wallpaperCropRect.w, 0.25, accuracy: 1e-9) // 1/4
    }

    func testLetterboxColorParsed() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio16x9
        s.letterboxColorHex = "FF0000"
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 3440, height: 1440),
            settings: s)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        layout.letterboxColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1, accuracy: 1e-3)
        XCTAssertEqual(g, 0, accuracy: 1e-3)
        XCTAssertEqual(b, 0, accuracy: 1e-3)
    }
}
