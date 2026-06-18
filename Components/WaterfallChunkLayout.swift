import SwiftUI

// MARK: - 瀑布流分块视图（纯 ZStack + 绝对定位实现）
//
// 设计目的：
// 替代之前基于 SwiftUI Layout protocol 的 `WaterfallChunkLayout`。
// 在 macOS 26 上 Layout protocol 实现会触发 SwiftUICore 的退化路径
// （LayoutEngineBox.explicitAlignment / UnaryLayoutEngine.sizeThatFits 系统库死循环），
// 表现为偶发主线程卡死 5+ 秒、CPU 100%。
//
// 新方案核心：
// 1. **完全不使用 SwiftUI Layout protocol**
// 2. 在视图构造时用纯 Swift 函数预计算每张卡片的绝对位置 (x, y, w, h)
// 3. chunk 容器用 `ZStack` + `.position` 把卡片直接放到指定坐标
// 4. chunk 整体 `.frame(height: precomputedHeight)` 把高度告诉外层 LazyVStack
//
// 这样 SwiftUI 在 chunk 内部不需要调用任何 Layout protocol 的
// measure/place 路径——彻底绕过死循环触发条件。
//
// 代价：chunk 内 30 张卡片全部实例化（不 lazy），但 KFImage 通过
// `hasStartedImageLoading` 仍是延迟加载，单 chunk 内存可控（~30 张）。

// MARK: - 瀑布流对齐算法（纯函数）

/// 一张卡片在 chunk 内的绝对布局信息。
struct WallpaperCardPlacement: Equatable {
    let frame: CGRect
}

/// chunk 整体布局结果。
struct WallpaperChunkLayoutResult: Equatable {
    let placements: [WallpaperCardPlacement]
    let totalHeight: CGFloat
}

/// 计算一个 chunk 的瀑布流布局：经典贪心分列 + 末尾对齐。
///
/// - Parameter cardCount: 卡片数量
/// - Parameter baseHeight: 每张卡片的"自然高度"闭包（按 wallpaper aspectRatio 算）
/// - Parameter maxHeight: 每张卡片允许加高到的"上限"闭包
/// - Parameter columns:    列数
/// - Parameter columnWidth: 每列宽度
/// - Parameter spacing:    列间距、行间距
/// - Parameter totalWidth: chunk 父容器的可用总宽（用于水平居中）
/// - Parameter alignToBaseline: 是否在 chunk 末尾把短列卡片反向加高对齐到最高列
///                              非末尾 chunk 应传 true，最末尾 chunk 传 false
///                              （避免 loadMore 时末尾卡片高度跳变）
@inline(__always)
func computeWallpaperChunkLayout(
    cardCount: Int,
    baseHeight: (Int) -> CGFloat,
    maxHeight: (Int) -> CGFloat,
    columns: Int,
    columnWidth: CGFloat,
    spacing: CGFloat,
    totalWidth: CGFloat,
    alignToBaseline: Bool
) -> WallpaperChunkLayoutResult {
    let columns = Swift.max(1, columns)
    let spacing = Swift.max(0, spacing)
    guard cardCount > 0, columnWidth > 0 else {
        return WallpaperChunkLayoutResult(placements: [], totalHeight: 0)
    }

    // ── Pass 1：经典瀑布贪心 ──
    // 把每张卡片放到当前最矮的列；记录 (列, 基础高度, 最大允许高度)
    struct Assignment {
        let columnIndex: Int
        let baseHeight: CGFloat
        let maxHeight: CGFloat
    }
    var assignments: [Assignment] = []
    assignments.reserveCapacity(cardCount)
    var columnHeights = Array(repeating: CGFloat(0), count: columns)

    for index in 0..<cardCount {
        let base = Swift.max(0, baseHeight(index))
        let raw = Swift.max(base, maxHeight(index))

        // 选当前最矮列（同高时优先左侧列，符合阅读顺序）
        var shortestCol = 0
        var shortestHeight = columnHeights[0]
        for col in 1..<columns where columnHeights[col] < shortestHeight {
            shortestCol = col
            shortestHeight = columnHeights[col]
        }
        assignments.append(Assignment(columnIndex: shortestCol, baseHeight: base, maxHeight: raw))

        // 累加该列高度（含 spacing；最末一张多加的 spacing 稍后扣除）
        columnHeights[shortestCol] += base + spacing
    }
    // 每列若有卡片，扣掉最末一张多加的 spacing
    for col in 0..<columns where columnHeights[col] > 0 {
        columnHeights[col] -= spacing
    }

    // ── Pass 2：H_target = max column height，作为对齐基准 ──
    let targetHeight = columnHeights.max() ?? 0

    // ── Pass 3：对每列从末尾卡片反向加高，分摊 deficit；不超过 maxHeight ──
    // 仅在 alignToBaseline = true 时执行，使 chunk 末尾三列总高度对齐，
    // 让下一 chunk 衔接处无可见分割。末尾 chunk 跳过此步——
    // 避免 loadMore 时末尾卡片高度跳变引起的"卡片放大缩小"视觉。
    var displayHeights = assignments.map { $0.baseHeight }
    if alignToBaseline {
        for col in 0..<columns {
            let columnIndices = assignments.indices.filter { assignments[$0].columnIndex == col }
            var deficit = targetHeight - columnHeights[col]
            guard deficit > 0.5 else { continue }

            // 从最后一张卡片往前调；每张可加高度 = maxHeight - 当前高度
            for cardIdx in columnIndices.reversed() {
                let canAdd = assignments[cardIdx].maxHeight - displayHeights[cardIdx]
                guard canAdd > 0 else { continue }
                let addAmount = Swift.min(deficit, canAdd)
                displayHeights[cardIdx] += addAmount
                deficit -= addAmount
                if deficit <= 0.5 { break }
            }
            // deficit 仍 > 0 时（卡片调整空间耗尽）接受残留差异——极端情况
        }
    }

    // ── Pass 4：用 displayHeights 算最终 frames ──
    // chunk 实际占用宽度（多列拼接），居中对齐到父容器宽度
    let actualChunkWidth = columnWidth * CGFloat(columns) + spacing * CGFloat(columns - 1)
    let leftOffset = Swift.max(0, (totalWidth - actualChunkWidth) / 2)

    var finalColumnY = Array(repeating: CGFloat(0), count: columns)
    var placements: [WallpaperCardPlacement] = []
    placements.reserveCapacity(assignments.count)
    for (idx, assignment) in assignments.enumerated() {
        let col = assignment.columnIndex
        let height = displayHeights[idx]
        let x = leftOffset + CGFloat(col) * (columnWidth + spacing)
        let y = finalColumnY[col]
        placements.append(WallpaperCardPlacement(
            frame: CGRect(x: x, y: y, width: columnWidth, height: height)
        ))
        finalColumnY[col] += height + spacing
    }

    // chunk 总高度 = 最高列的累计高度 - 多加的最后一行 spacing
    let hasContent = finalColumnY.contains(where: { $0 > 0 })
    let totalHeight = (finalColumnY.max() ?? 0) - (hasContent ? spacing : 0)

    return WallpaperChunkLayoutResult(
        placements: placements,
        totalHeight: Swift.max(0, totalHeight)
    )
}
