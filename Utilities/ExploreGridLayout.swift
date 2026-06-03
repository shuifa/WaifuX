import SwiftUI

/// 探索页网格：列数 2…4（中间宽度默认约 3 列）、间距 16pt。
enum ExploreGridLayout {
    static let spacing: CGFloat = 16

    /// `contentWidth` 为已扣除水平内边距后的可用宽度。
    static func columnCount(for contentWidth: CGFloat) -> Int {
        let w = max(0, contentWidth)
        let g = spacing
        // 列数越大，对单卡最小宽度要求略提高，避免过窄时仍挤 4 列；中间区间自然落在 3 列。
        let tiers: [(cols: Int, minCell: CGFloat)] = [
            (4, 210),
            (3, 195),
            (2, 160)
        ]
        for tier in tiers {
            let cell = (w - CGFloat(tier.cols - 1) * g) / CGFloat(tier.cols)
            if cell >= tier.minCell {
                return tier.cols
            }
        }
        return 2
    }

    static func columns(for contentWidth: CGFloat) -> [GridItem] {
        let n = columnCount(for: contentWidth)
        return Array(
            repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
            count: n
        )
    }
}

private struct ExploreColumnDistributionKey: Equatable {
    let itemCount: Int
    let version: Int
    let columnCount: Int
    let cardWidthUnits: Int
    let spacingUnits: Int
}

@MainActor
final class ExploreColumnDistributionCache<Item>: ObservableObject {
    private var cachedKey: ExploreColumnDistributionKey?
    private var cachedColumnIndices: [[Int]] = []

    func columns(
        for items: [Item],
        version: Int,
        columnCount: Int,
        cardWidth: CGFloat,
        spacing: CGFloat,
        height: (Item) -> CGFloat
    ) -> [[Item]] {
        let key = ExploreColumnDistributionKey(
            itemCount: items.count,
            version: version,
            columnCount: columnCount,
            cardWidthUnits: Int((cardWidth * 100).rounded()),
            spacingUnits: Int((spacing * 100).rounded())
        )

        if cachedKey != key {
            cachedKey = key
            cachedColumnIndices = distributeIndices(
                for: items,
                columnCount: columnCount,
                spacing: spacing,
                height: height
            )
        }

        return cachedColumnIndices.map { indices in
            indices.compactMap { index in
                guard items.indices.contains(index) else { return nil }
                return items[index]
            }
        }
    }

    func invalidate() {
        cachedKey = nil
        cachedColumnIndices = []
    }

    private func distributeIndices(
        for items: [Item],
        columnCount: Int,
        spacing: CGFloat,
        height: (Item) -> CGFloat
    ) -> [[Int]] {
        let safeColumnCount = max(1, columnCount)
        var columns: [[Int]] = Array(repeating: [], count: safeColumnCount)
        var columnHeights: [CGFloat] = Array(repeating: 0, count: safeColumnCount)

        for (index, item) in items.enumerated() {
            let itemHeight = max(1, height(item))
            let minHeight = columnHeights.min() ?? 0
            let column = columnHeights.firstIndex(of: minHeight) ?? 0
            columns[column].append(index)
            columnHeights[column] += itemHeight + spacing
        }

        return columns
    }
}

// MARK: - 增量瀑布流分配器

/// 保持 column 分配状态，追加新 items 时只分配新 item，不重算已有 item。
/// 仅在列数/卡片宽度变化或 feed 被替换时触发全量重算，避免滚动加载时重复遍历全部 items。
@MainActor
final class ExploreIncrementalDistributor<Item: Identifiable>: ObservableObject {
    private var columnItems: [[Item]] = []
    private var columnHeights: [CGFloat] = []
    private var itemIDs: Set<Item.ID> = []
    private var linearItemIDs: [Item.ID] = []
    private var lastColumnCount = 0
    private var lastCardWidth: CGFloat = 0
    private var lastSpacing: CGFloat = 0

    /// 接收当前完整 items 列表，只有确认是尾部追加时才增量分配。
    func append(
        items newItems: [Item],
        columnCount: Int,
        cardWidth: CGFloat,
        spacing: CGFloat,
        height: (Item) -> CGFloat
    ) -> [[Item]] {
        let validColumnCount = max(1, columnCount)
        let validCardWidth = max(1, cardWidth)
        let incomingIDs = newItems.map(\.id)

        if incomingIDs.isEmpty {
            invalidate()
            return Array(repeating: [], count: validColumnCount)
        }

        // 如果列数或卡片宽度变化（窗口缩放），全量重算
        if columnCount != lastColumnCount || abs(cardWidth - lastCardWidth) > 1 || abs(spacing - lastSpacing) > 0.5 {
            reset(with: newItems, columnCount: validColumnCount, cardWidth: validCardWidth, spacing: spacing, height: height)
            return columnItems
        }

        // 搜索/筛选/重置会替换整个 feed；此时不能沿用上一轮的列状态。
        if !linearItemIDs.isEmpty {
            let isAppendOnly = incomingIDs.count >= linearItemIDs.count &&
                zip(linearItemIDs, incomingIDs).allSatisfy { $0 == $1 }

            if !isAppendOnly {
                reset(with: newItems, columnCount: validColumnCount, cardWidth: validCardWidth, spacing: spacing, height: height)
                return columnItems
            }
        }

        // 过滤出真正的新 items
        let toAdd = newItems.filter { !itemIDs.contains($0.id) }
        guard !toAdd.isEmpty else { return columnItems }

        // 补齐列数（初次使用或列数增加时）
        while columnItems.count < validColumnCount {
            columnItems.append([])
            columnHeights.append(0)
        }

        for item in toAdd {
            let h = max(1, height(item))
            let minH = columnHeights.min() ?? 0
            let col = columnHeights.firstIndex(of: minH) ?? 0
            columnItems[col].append(item)
            columnHeights[col] += h + spacing
            itemIDs.insert(item.id)
        }
        linearItemIDs = incomingIDs

        return columnItems
    }

    /// 全量重算所有 items
    func reset(
        with items: [Item],
        columnCount: Int,
        cardWidth: CGFloat,
        spacing: CGFloat,
        height: (Item) -> CGFloat
    ) {
        let validColumnCount = max(1, columnCount)
        columnItems = Array(repeating: [], count: validColumnCount)
        columnHeights = Array(repeating: 0, count: validColumnCount)
        itemIDs.removeAll()
        linearItemIDs = items.map(\.id)

        for item in items {
            itemIDs.insert(item.id)
            let h = max(1, height(item))
            let minH = columnHeights.min() ?? 0
            let col = columnHeights.firstIndex(of: minH) ?? 0
            columnItems[col].append(item)
            columnHeights[col] += h + spacing
        }

        lastColumnCount = validColumnCount
        lastCardWidth = max(1, cardWidth)
        lastSpacing = spacing
    }

    /// 清空分配状态（filter/搜索切换时调用）
    func invalidate() {
        columnItems = []
        columnHeights = []
        itemIDs = []
        linearItemIDs = []
        lastColumnCount = 0
        lastCardWidth = 0
        lastSpacing = 0
    }
}
