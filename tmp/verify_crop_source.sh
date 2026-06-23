#!/bin/bash
set -e
cd "$(dirname "$0")/.."
# 用 swiftc 编译源码 + 临时测试驱动（多文件编译模式下，入口必须是 @main 或 main.swift）
cat > /tmp/test_crop_driver.swift <<'EOF'
import Foundation
import CoreGraphics

@main
struct CropDriver {
    static func main() {
        var s = DisplayCropSettings()
        s.aspectPreset = .ratio32x9
        s.zoom = 1
        s.pan = CGPoint(x: 0.5, y: 0)
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 1920, height: 1080),
            settings: s)
        assert(abs(layout.wallpaperCropRect.y - 0.0) < 1e-9, "pan.y=0 应看到上方 crop.y=0，实际 \(layout.wallpaperCropRect.y)")
        print("源码冒烟通过：32:9 pan.y=0 → crop.y=\(layout.wallpaperCropRect.y)")
    }
}
EOF
swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  Models/DisplayCropSettings.swift Services/CropLayoutEngine.swift /tmp/test_crop_driver.swift -o /tmp/test_crop_driver
/tmp/test_crop_driver