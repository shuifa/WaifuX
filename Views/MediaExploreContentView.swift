import SwiftUI
import AppKit
import Kingfisher
@preconcurrency import Translation

private struct MediaLoadMoreSentinelMinYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next < value {
            value = next
        }
    }
}

// MARK: - MediaExploreContentView - 媒体探索页

struct MediaExploreContentView: View {
    private static let scrollCoordinateSpaceName = "media-explore-scroll"
    private static let loadMoreTriggerThreshold: CGFloat = 120

    @ObservedObject var viewModel: MediaExploreViewModel
    @Binding var selectedMedia: MediaItem?
    var isVisible: Bool = true
    @StateObject private var exploreAtmosphere = ExploreAtmosphereController(wallpaperMode: false)
    @ObservedObject private var arcSettings = ArcBackgroundSettings.shared
    @ObservedObject private var workshopSourceManager = WorkshopSourceManager.shared
    @ObservedObject private var videoWallpaperManager = VideoWallpaperManager.shared
    @ObservedObject private var wallpaperEngineBridge = WallpaperEngineXBridge.shared
    @StateObject private var translationBridge = SearchTranslationBridge()

    @State private var selectedCategory: MediaCategory = .all
    @State private var selectedHotTag: MediaHotTag?
    @State private var selectedSort: MediaSortOption = .newest
    @State private var searchText = ""
    @State private var isLoadingMore = false
    @State private var isInitialLoading = false
    @State private var isFirstAppearance = true
    @State private var loadMoreFailed = false
    @State private var lastSyncedFirstItemID: String?
    @State private var isApplyingProgrammaticReset = false

    @State private var searchTask: Task<Void, Never>?
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var pendingSearchText: String?
    /// 翻译后的实际搜索词（英文），与 searchText（原始中文）分离
    @State private var mediaSearchQuery: String = ""
    @State private var sentinelDebounceTask: DispatchWorkItem?
    private var shouldUseLightweightEffects: Bool {
        (videoWallpaperManager.isVideoWallpaperActive && !videoWallpaperManager.isPaused) ||
        (wallpaperEngineBridge.isControllingExternalEngine && !wallpaperEngineBridge.isExternalPaused)
    }

    // Grid 控制
    @State private var showScrollToTop: Bool = false
    @State private var outerScrollToTopToken: Int = 0

    // Workshop 筛选
    @State private var selectedWorkshopTags: Set<WorkshopSourceManager.WorkshopTag> = []
    @State private var selectedWorkshopType: WorkshopSourceManager.WorkshopTypeFilter = .all
    @State private var selectedWorkshopContentLevel: WorkshopSourceManager.WorkshopContentLevel? = .everyone
    @State private var selectedWorkshopResolution: WorkshopSourceManager.WorkshopResolution? = nil
    @State private var workshopSearchQuery: String = ""
    @State private var selectedWorkshopSort: WorkshopSortOption = .trendWeek
    @State private var showWorkshopURLSheet = false
    @State private var workshopURLInput = ""
    @State private var isResolvingWorkshopURL = false
    @State private var workshopURLError: String?

    // Dynamic Wallpaper (DongTai) 筛选
    @State private var selectedDongTaiCategories: Set<DynamicWallpaperCategory> = []
    @State private var selectedDongTaiListType: DynamicWallpaperListType = .all
    @State private var selectedDongTaiSort: DynamicWallpaperSortOption = .popular
    @State private var dongtaiFilterAudio: Bool? = nil
    @State private var dongtaiFilterFourK: Bool? = nil
    private var workshopService: WorkshopService {
        WorkshopService.shared
    }

    var body: some View {
        GeometryReader { geometry in
            let gridContentWidth = max(0, geometry.size.width - 56)

            ZStack {
                if arcSettings.compactMode {
                    arcSettings.compactBackground
                        .ignoresSafeArea()
                } else {
                    ArcAtmosphereBackground(
                        tint: exploreAtmosphere.tint,
                        referenceImage: shouldUseLightweightEffects ? nil : exploreAtmosphere.referenceImage,
                        isLightMode: arcSettings.isLightMode,
                        dotGridOpacity: arcSettings.dotGridOpacity,
                        useNoise: true,
                        grainIntensity: arcSettings.exploreGrainMedia,
                        lightweight: shouldUseLightweightEffects
                    )
                    .ignoresSafeArea()
                }

                ZStack {
                    contentArea(
                        gridContentWidth: gridContentWidth,
                        viewportHeight: geometry.size.height
                    )
                        .padding(.horizontal, 28)
                        .frame(width: geometry.size.width, alignment: .leading)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
                        .environment(\.arcIsLightMode, arcSettings.isLightMode)
                        .disabled(isInitialLoading)

                    bottomLoadingOverlay

                    scrollToTopButton
                }
            }
        }
        .sheet(isPresented: $showWorkshopURLSheet) {
            WorkshopURLInputSheet(
                urlInput: $workshopURLInput,
                errorMessage: workshopURLError,
                isLoading: isResolvingWorkshopURL,
                onSubmit: { handleWorkshopURLSubmit() },
                onDismiss: { showWorkshopURLSheet = false }
            )
        }
        .onAppear {
            if isFirstAppearance {
                Task { await performFirstAppearanceLoad() }
            } else {
                Task { await handleInitialLoad() }
            }
        }
        .onChange(of: isVisible) { _, visible in
            if !visible {
                cancelTasks()
                exploreAtmosphere.pause()
            } else {
                syncAtmosphereIfNeeded()
            }
        }
        .onChange(of: arcSettings.isLightMode) { _, _ in }
        .onChange(of: selectedHotTag) { _, _ in handleFilterChange() }
        .onChange(of: selectedWorkshopSort) { _, _ in handleWorkshopSortChange() }
        .onChange(of: selectedDongTaiSort) { _, _ in handleDongTaiSortChange() }
        .onChange(of: searchText) { _, newValue in
            translationBridge.detectLanguage(for: newValue)
            handleFilterChange()
        }
        .onReceive(translationBridge.$translationCompleted) { _ in
            handleTranslationCompleted()
        }
        .onChange(of: viewModel.isLoading) { _, newValue in
            if newValue {
                // 加载开始时自动刷新
            } else {
                syncAtmosphereIfNeeded()
            }
        }
        .onChange(of: viewModel.libraryContentRevision) { _, _ in }
        .onChange(of: viewModel.items.count) { _, newCount in
            if newCount > 60 { showScrollToTop = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .workshopSourceChanged)) { _ in
            handleSourceChange()
        }
    }

    @ViewBuilder
    private func contentArea(gridContentWidth: CGFloat, viewportHeight: CGFloat) -> some View {
        if viewModel.items.isEmpty {
            legacyScrollContent(gridContentWidth: gridContentWidth) {
                Group {
                    if isMediaLoadingState {
                        loadingState
                    } else {
                        emptyState
                    }
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            }
        } else {
            if #available(macOS 15.0, *) {
                scrollViewModern(gridContentWidth: gridContentWidth)
            } else {
                scrollViewLegacy(gridContentWidth: gridContentWidth, viewportHeight: viewportHeight)
            }
        }
    }

    // MARK: - macOS 15+：使用 onScrollGeometryChange

    @available(macOS 15.0, *)
    private func scrollViewModern(gridContentWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("media-scroll-top")
                    headerStack
                    mediaGrid(contentWidth: gridContentWidth)
                }
                .coordinateSpace(name: Self.scrollCoordinateSpaceName)
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { geometry in
                let bottomOffset = geometry.contentOffset.y + geometry.containerSize.height
                return geometry.contentSize.height - bottomOffset
            }, action: { _, distanceFromBottom in
                guard isVisible, distanceFromBottom.isFinite else { return }
                if distanceFromBottom <= Self.loadMoreTriggerThreshold {
                    triggerLoadMore()
                }
            })
            .scrollDisabled(!isVisible)
            .onChange(of: outerScrollToTopToken) { _, _ in
                withAnimation(nil) {
                    proxy.scrollTo("media-scroll-top", anchor: .top)
                }
            }
        }
    }

    // MARK: - macOS 14：使用 PreferenceKey

    private func scrollViewLegacy(gridContentWidth: CGFloat, viewportHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("media-scroll-top")
                    headerStack
                    mediaGrid(contentWidth: gridContentWidth)
                    loadMoreSentinel
                }
                .coordinateSpace(name: Self.scrollCoordinateSpaceName)
            }
            .onPreferenceChange(MediaLoadMoreSentinelMinYPreferenceKey.self) { sentinelMinY in
                sentinelDebounceTask?.cancel()
                let task = DispatchWorkItem {
                    handleLoadMoreSentinelPosition(sentinelMinY, viewportHeight: viewportHeight)
                }
                sentinelDebounceTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: task)
            }
            .scrollDisabled(!isVisible)
            .onChange(of: outerScrollToTopToken) { _, _ in
                withAnimation(nil) {
                    proxy.scrollTo("media-scroll-top", anchor: .top)
                }
            }
        }
    }

    /// 仅用于"骨架/空状态"等无网格场景的兜底滚动容器（保留 header）
    private func legacyScrollContent<Content: View>(gridContentWidth: CGFloat, @ViewBuilder body: () -> Content) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                headerStack
                body()
            }
            .padding(.bottom, 48)
        }
        .scrollDisabled(!isVisible)
    }

    private var bottomLoadingOverlay: some View {
        VStack {
            Spacer()
            if loadMoreFailed {
                BottomLoadingFailedCard {
                    triggerLoadMore()
                }
                .padding(.bottom, 60)
            } else if isLoadingMore || (viewModel.isLoadingMore && !viewModel.items.isEmpty) || (viewModel.isLoading && !viewModel.items.isEmpty) {
                BottomLoadingCard(isLoading: true)
                    .padding(.bottom, 60)
            } else if !isLoadingMore && !viewModel.hasMorePages && !viewModel.items.isEmpty {
                BottomNoMoreCard()
                    .padding(.bottom, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var scrollToTopButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if showScrollToTop {
                    Button {
                        outerScrollToTopToken &+= 1
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: 44, height: 44)
                            .liquidGlassSurface(.regular, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 28)
                    .padding(.bottom, 120)
                    .contentShape(Rectangle())
                    .zIndex(100)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .zIndex(100)
        .animation(.easeInOut(duration: 0.3), value: showScrollToTop)
    }

    // MARK: - Header

    private var headerStack: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroSection
            categorySection
            switch workshopSourceManager.activeSource {
            case .wallpaperEngine:
                filterSection
                workshopTagsSection
                activeFiltersSection
            case .dongtai:
                dongtaiFilterSection
                dongtaiActiveFiltersSection
            default:
                EmptyView()
            }
            contentHeader.padding(.top, 12)
        }
        .padding(.top, 80)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
        .environment(\.arcIsLightMode, arcSettings.isLightMode)
    }

    // MARK: - Sections

    @ViewBuilder
    private var heroSection: some View {
        if #available(macOS 15.0, *) {
            TranslationTaskHost(bridge: translationBridge) {
                heroSectionContent
            }
        } else {
            heroSectionContent
        }
    }

    private var heroSectionContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerTitle
            searchRow
            if workshopSourceManager.activeSource != .wallpaperEngine && workshopSourceManager.activeSource != .dongtai {
                hotTagsRow
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(greetingText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(arcSettings.secondaryText.opacity(0.85))

                // 源切换 Menu（支持扩展更多源）
                Menu {
                    ForEach(WorkshopSourceManager.SourceType.allCases, id: \.self) { source in
                        Button {
                            workshopSourceManager.switchTo(source)
                        } label: {
                            HStack(spacing: 8) {
                                Text(source.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                if source == workshopSourceManager.activeSource {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                }
                            }
                        }
                    }
                } label: {
                    Text(workshopSourceManager.activeSource.displayName)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(arcSettings.primaryText.opacity(0.75))
                }
                .menuStyle(.borderlessButton)
                .offset(y: 1.5)
            }

            Text(t("exploreMedia"))
                .font(.system(size: 32, weight: .bold, design: .serif))
                .tracking(-0.5)
                .foregroundStyle(arcSettings.primaryText)
                .lineLimit(1)
        }
    }

    private var searchRow: some View {
        HStack(alignment: .center, spacing: 12) {
            ExploreSearchBar(
                text: $searchText,
                placeholder: t("search.placeholder"),
                tint: exploreAtmosphere.tint.primary,
                onSubmit: { submitSearch() },
                onClear: { searchText = ""; translationBridge.reset(); submitSearch(with: "") },
                translatedText: (workshopSourceManager.activeSource != .wallpaperEngine && workshopSourceManager.activeSource != .dongtai) ? translationBridge.translatedText : nil,
                isTranslating: (workshopSourceManager.activeSource != .wallpaperEngine && workshopSourceManager.activeSource != .dongtai) ? translationBridge.isTranslating : false,
                onDismissTranslation: (workshopSourceManager.activeSource != .wallpaperEngine && workshopSourceManager.activeSource != .dongtai) ? {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        translationBridge.dismiss()
                    }
                } : nil
            )

            WorkshopURLInputButton(tint: exploreAtmosphere.tint.primary) {
                showWorkshopURLSheet = true
            }

            if !arcSettings.compactMode {
                ArcBackgroundPanelButton(tint: exploreAtmosphere.tint.primary, grainIntensity: $arcSettings.exploreGrainMedia) {
                    randomizeAtmosphere()
                }
            }

            ResetFiltersButton(tint: exploreAtmosphere.tint.secondary) {
                resetAllFilters(reloadData: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hotTagsRow: some View {
        motionBGTagsRow
    }

    private var motionBGTagsRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(t("hotWallpaper") + ":")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.4))

            ForEach(MediaHotTag.allCases) { tag in
                TagChip(
                    title: tag.title,
                    isSelected: selectedHotTag == tag
                ) {
                    withAnimation(AppFluidMotion.interactiveSpring) {
                        selectedHotTag = selectedHotTag == tag ? nil : tag
                    }
                }
            }
        }
    }

    private func applyWorkshopFilters(query: String? = nil) async {
        prepareForFeedReplacement()
        viewModel.clearItems()

        let tags = selectedWorkshopTags.map { $0.name }
        let searchQuery = query ?? workshopSearchQuery
        await viewModel.loadWorkshopWithFilters(
            query: searchQuery,
            tags: tags,
            type: selectedWorkshopType,
            contentLevel: selectedWorkshopContentLevel,
            resolution: selectedWorkshopResolution?.tagValue
        )
    }

    @ViewBuilder
    private var categorySection: some View {
        switch workshopSourceManager.activeSource {
        case .wallpaperEngine:
            workshopTypeSection
        case .dongtai:
            dongtaiCategorySection
        default:
            FlowLayout(spacing: 12) {
                ForEach(MediaCategory.allCases) { category in
                    CategoryChip(
                        icon: category.icon,
                        title: category.title,
                        accentColors: category.accentColors,
                        isSelected: selectedCategory == category
                    ) {
                        selectCategory(category)
                    }
                }
            }
        }
    }

    private var workshopTypeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("categories"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.46))
            FlowLayout(spacing: 12) {
                ForEach(WorkshopSourceManager.WorkshopTypeFilter.allCases) { type in
                    CategoryChip(
                        icon: type.icon,
                        title: type.displayName,
                        accentColors: type.accentColors,
                        isSelected: selectedWorkshopType.id == type.id
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            selectedWorkshopType = type
                            Task { await applyWorkshopFilters() }
                        }
                    }
                }
                workshopResolutionMenu
            }
        }
    }

    private var workshopTagsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("tags"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.46))
            FlowLayout(spacing: 12) {
                ForEach(workshopSourceManager.availableTags) { tag in
                    CategoryChip(
                        icon: tag.icon,
                        title: tag.displayName,
                        accentColors: tag.accentColors,
                        isSelected: selectedWorkshopTags.contains(tag)
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            if selectedWorkshopTags.contains(tag) {
                                selectedWorkshopTags.remove(tag)
                            } else {
                                selectedWorkshopTags.insert(tag)
                            }
                            Task { await applyWorkshopFilters() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var filterSection: some View {
        if workshopSourceManager.activeSource == .wallpaperEngine {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("contentLevel"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(arcSettings.secondaryText.opacity(0.46))
                FlowLayout(spacing: 10) {
                    ForEach(visibleWorkshopContentLevels) { level in
                        FilterChip(
                            title: level.title,
                            subtitle: level.subtitle,
                            isSelected: selectedWorkshopContentLevel?.id == level.id,
                            tint: level.tint
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                if selectedWorkshopContentLevel?.id == level.id {
                                    // 点击已选中项：回到默认 Everyone（不允许空选）
                                    selectedWorkshopContentLevel = .everyone
                                } else {
                                    selectedWorkshopContentLevel = level
                                }
                                Task { await applyWorkshopFilters() }
                            }
                        }
                    }
                }
            }
        }
    }

    private var workshopResolutionMenu: some View {
        Menu {
            Button(t("allResolutions")) {
                selectedWorkshopResolution = nil
                Task { await applyWorkshopFilters() }
            }
            Divider()
            ForEach(workshopSourceManager.availableResolutions) { res in
                let isSelected = selectedWorkshopResolution?.id == res.id
                Button {
                    selectedWorkshopResolution = isSelected ? nil : res
                    Task { await applyWorkshopFilters() }
                } label: {
                    HStack {
                        Text(res.display)
                        if isSelected { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            let hasResolution = selectedWorkshopResolution != nil
            HStack(spacing: 6) {
                Image(systemName: "aspectratio").font(.system(size: 11, weight: .semibold))
                Text(hasResolution ? (selectedWorkshopResolution?.display ?? "") : t("resolution"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(hasResolution ? arcSettings.primaryText.opacity(0.95) : arcSettings.secondaryText.opacity(0.7))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .exploreFrostedCapsule(
                tint: exploreAtmosphere.tint.primary,
                material: hasResolution ? .regularMaterial : .ultraThinMaterial,
                tintLayerOpacity: hasResolution ? 0.1 : 0.03
            )
        }
        .menuStyle(.borderlessButton)
        .offset(y: 1)
        .frame(height: 34)
    }

    private var visibleWorkshopContentLevels: [WorkshopSourceManager.WorkshopContentLevel] {
        if workshopSourceManager.isSteamAuthenticated && UserDefaults.standard.bool(forKey: "show_all_workshop_content") {
            [.everyone, .questionable, .mature]
        } else {
            [.everyone, .questionable]
        }
    }

    @ViewBuilder
    private var activeFiltersSection: some View {
        if workshopSourceManager.activeSource == .wallpaperEngine {
            let chips = workshopActiveFilterChips
            if !chips.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text(t("currentFilters"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(arcSettings.secondaryText.opacity(0.46))
                        Button(t("clear")) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                selectedWorkshopTags = []
                                selectedWorkshopContentLevel = .everyone
                                selectedWorkshopType = .all
                                selectedWorkshopResolution = nil
                                Task { await applyWorkshopFilters() }
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(arcSettings.secondaryText.opacity(0.72))
                        .buttonStyle(.plain)
                    }
                    FlowLayout(spacing: 10) {
                        ForEach(chips) { chip in
                            WorkshopActiveFilterChip(
                                title: chip.title,
                                accentHex: chip.accentHex
                            ) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    removeWorkshopFilter(chip)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private struct WorkshopFilterChipData: Identifiable {
        let id: String
        let title: String
        let accentHex: String
        let kind: Kind
        enum Kind { case type, tag, level, resolution }
    }

    private var workshopActiveFilterChips: [WorkshopFilterChipData] {
        var chips: [WorkshopFilterChipData] = []
        if selectedWorkshopType != .all {
            chips.append(WorkshopFilterChipData(
                id: "type_\(selectedWorkshopType.id)",
                title: selectedWorkshopType.displayName,
                accentHex: selectedWorkshopType.accentColors.first ?? "FFFFFF",
                kind: .type
            ))
        }
        for tag in selectedWorkshopTags {
            chips.append(WorkshopFilterChipData(
                id: "tag_\(tag.id)",
                title: tag.displayName,
                accentHex: tag.accentColors.first ?? "FFFFFF",
                kind: .tag
            ))
        }
        if let level = selectedWorkshopContentLevel, level != .everyone {
            chips.append(WorkshopFilterChipData(
                id: "level_\(level.id)",
                title: level.title,
                accentHex: level.accentHex,
                kind: .level
            ))
        }
        if let res = selectedWorkshopResolution {
            chips.append(WorkshopFilterChipData(
                id: "res_\(res.id)",
                title: res.display,
                accentHex: "3A86FF",
                kind: .resolution
            ))
        }
        return chips
    }

    private func removeWorkshopFilter(_ chip: WorkshopFilterChipData) {
        switch chip.kind {
        case .type:
            selectedWorkshopType = .all
        case .tag:
            let tagId = chip.id.replacingOccurrences(of: "tag_", with: "")
            selectedWorkshopTags = selectedWorkshopTags.filter { $0.id != tagId }
        case .level:
            selectedWorkshopContentLevel = .everyone
        case .resolution:
            selectedWorkshopResolution = nil
        }
        Task { await applyWorkshopFilters() }
    }

    // MARK: - DongTai 分类

    private var dongtaiCategorySection: some View {
        FlowLayout(spacing: 12) {
            // 列表类型切换（隐藏普通视频选项）
            ForEach(DynamicWallpaperListType.allCases.filter { $0 != .collection }) { listType in
                CategoryChip(
                    icon: listTypeIcon(listType),
                    title: listType.displayName,
                    accentColors: ["FF5E98", "FF9A5B"],
                    isSelected: selectedDongTaiListType == listType
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedDongTaiListType = listType
                        Task { await applyDongTaiFilters() }
                    }
                }
            }
            // 分类标签
            ForEach(DynamicWallpaperCategory.allCases) { category in
                CategoryChip(
                    icon: category.icon,
                    title: category.title,
                    accentColors: category.accentColors,
                    isSelected: selectedDongTaiCategories.contains(category)
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        if selectedDongTaiCategories.contains(category) {
                            selectedDongTaiCategories.remove(category)
                        } else {
                            selectedDongTaiCategories.insert(category)
                        }
                        Task { await applyDongTaiFilters() }
                    }
                }
            }
        }
    }

    private func listTypeIcon(_ type: DynamicWallpaperListType) -> String {
        switch type {
        case .all: return "square.grid.2x2"
        case .collection: return "film.stack.fill"
        case .exclusive: return "star.fill"
        }
    }

    // MARK: - DongTai 筛选区

    @ViewBuilder
    private var dongtaiFilterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("dongtai.filters"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.46))
            FlowLayout(spacing: 10) {
                // 音频筛选
                dongtaiAudioFilterChip
                // 4K 筛选
                dongtaiFourKFilterChip
            }
        }
    }

    private var dongtaiAudioFilterChip: some View {
        FilterChip(
            title: t("dongtai.filter.hasAudio"),
            subtitle: "",
            isSelected: dongtaiFilterAudio == true,
            tint: LiquidGlassColors.onlineGreen
        ) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                if dongtaiFilterAudio == true {
                    dongtaiFilterAudio = nil
                } else {
                    dongtaiFilterAudio = true
                    dongtaiFilterFourK = nil // 互斥，便于 UI 清晰
                }
                Task { await applyDongTaiFilters() }
            }
        }
    }

    private var dongtaiFourKFilterChip: some View {
        FilterChip(
            title: t("dongtai.filter.fourK"),
            subtitle: "",
            isSelected: dongtaiFilterFourK == true,
            tint: LiquidGlassColors.primaryPink
        ) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                if dongtaiFilterFourK == true {
                    dongtaiFilterFourK = nil
                } else {
                    dongtaiFilterFourK = true
                    dongtaiFilterAudio = nil // 互斥
                }
                Task { await applyDongTaiFilters() }
            }
        }
    }

    // MARK: - DongTai 活跃筛选标签

    @ViewBuilder
    private var dongtaiActiveFiltersSection: some View {
        let chips = dongtaiActiveFilterChips
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(t("currentFilters"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(arcSettings.secondaryText.opacity(0.46))
                    Button(t("clear")) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            selectedDongTaiCategories = []
                            selectedDongTaiListType = .all
                            dongtaiFilterAudio = nil
                            dongtaiFilterFourK = nil
                            Task { await applyDongTaiFilters() }
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(arcSettings.secondaryText.opacity(0.72))
                    .buttonStyle(.plain)
                }
                FlowLayout(spacing: 10) {
                    ForEach(chips) { chip in
                        WorkshopActiveFilterChip(
                            title: chip.title,
                            accentHex: chip.accentHex
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                removeDongTaiFilter(chip)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct DongTaiFilterChipData: Identifiable {
        let id: String
        let title: String
        let accentHex: String
        let kind: Kind
        enum Kind { case category, listType, audio, fourK }
    }

    private var dongtaiActiveFilterChips: [DongTaiFilterChipData] {
        var chips: [DongTaiFilterChipData] = []
        if selectedDongTaiListType != .all {
            chips.append(DongTaiFilterChipData(
                id: "list_\(selectedDongTaiListType.id)",
                title: selectedDongTaiListType.displayName,
                accentHex: "FF5E98",
                kind: .listType
            ))
        }
        for cat in selectedDongTaiCategories {
            chips.append(DongTaiFilterChipData(
                id: "cat_\(cat.rawValue)",
                title: cat.title,
                accentHex: cat.accentColors.first ?? "FFFFFF",
                kind: .category
            ))
        }
        if dongtaiFilterAudio == true {
            chips.append(DongTaiFilterChipData(
                id: "audio",
                title: t("dongtai.filter.hasAudio"),
                accentHex: "43C463",
                kind: .audio
            ))
        }
        if dongtaiFilterFourK == true {
            chips.append(DongTaiFilterChipData(
                id: "fourk",
                title: t("dongtai.filter.fourK"),
                accentHex: "FF5A7D",
                kind: .fourK
            ))
        }
        return chips
    }

    private func removeDongTaiFilter(_ chip: DongTaiFilterChipData) {
        switch chip.kind {
        case .category:
            let catId = chip.id.replacingOccurrences(of: "cat_", with: "")
            selectedDongTaiCategories = selectedDongTaiCategories.filter { $0.rawValue != catId }
        case .listType:
            selectedDongTaiListType = .all
        case .audio:
            dongtaiFilterAudio = nil
        case .fourK:
            dongtaiFilterFourK = nil
        }
        Task { await applyDongTaiFilters() }
    }

    /// 应用 DongTai 筛选（组合全部活跃筛选条件）
    private func applyDongTaiFilters(query: String? = nil) async {
        prepareForFeedReplacement()
        // 先重置 isLoading 避免被 loadDongTaiFeedInternal 的 guard 阻塞
        viewModel.isLoading = false
        viewModel.clearItems()

        let searchQuery = query ?? searchText
        let dongtaiQuery = workshopSourceManager.activeSource == .dongtai ? searchQuery : ""

        // 同步筛选状态到 ViewModel 并组合全部条件
        await viewModel.loadDongTaiWithAllFilters(
            query: dongtaiQuery,
            categories: selectedDongTaiCategories,
            listType: selectedDongTaiListType,
            sortBy: selectedDongTaiSort,
            hasAudio: dongtaiFilterAudio,
            isFourK: dongtaiFilterFourK
        )

        // 强制刷新网格：DongTai 查询为同步操作，isLoading 变化太快，
        // SwiftUI 的 .onChange(of: viewModel.isLoading) 无法捕捉到中间状态，
        // 此处显式通知网格重新加载
        syncAtmosphereIfNeeded()

    }

    private var contentHeader: some View {
        HStack(alignment: .center) {
            Text("\(formattedCount(viewModel.items.count)) \(t("media.count")) · \(t("media.loaded")) \(formattedCount(viewModel.items.count))")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.64))

            Spacer()

            switch workshopSourceManager.activeSource {
            case .wallpaperEngine:
                SortMenu(options: WorkshopSortOption.allCases, selected: $selectedWorkshopSort, tint: exploreAtmosphere.tint.primary)
            case .dongtai:
                SortMenu(options: DynamicWallpaperSortOption.allCases, selected: $selectedDongTaiSort, tint: exploreAtmosphere.tint.primary)
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Grid

    private func mediaGrid(contentWidth: CGFloat) -> some View {
        let spacing: CGFloat = ExploreGridLayout.spacing
        let columnCount = ExploreGridLayout.columnCount(for: contentWidth)
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        let cardWidth = max(1, floor((contentWidth - totalSpacing) / CGFloat(columnCount)))
        let items = viewModel.items
        let columnItems = distributeMediaToColumns(
            items: items,
            cardWidth: cardWidth,
            columnCount: columnCount,
            spacing: spacing
        )

        return HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<columnCount, id: \.self) { columnIndex in
                let items = columnItems[safe: columnIndex] ?? []
                LazyVStack(spacing: spacing) {
                    ForEach(items) { media in
                        MediaCardView(
                            media: media,
                            isFavorite: viewModel.isFavorite(media),
                            cardWidth: cardWidth
                        ) {
                            selectedMedia = media
                        }
                    }
                }
                .frame(width: cardWidth)
            }
        }
    }

    /// 瀑布流：将所有媒体项按最短列连续分配到各列。
    /// 与分页块解耦，新追加的项始终流入当前最短列底部，不会出现在视口上方。
    private func distributeMediaToColumns(items: [MediaItem], cardWidth: CGFloat, columnCount: Int, spacing: CGFloat) -> [[MediaItem]] {
        let safeColumnCount = max(1, columnCount)
        var columns: [[MediaItem]] = Array(repeating: [], count: safeColumnCount)
        var columnHeights: [CGFloat] = Array(repeating: 0, count: safeColumnCount)

        for item in items {
            let aspect = parsedMediaAspectRatio(item)
            let maxImageHeight = cardWidth * 1.8
            let itemHeight = min(cardWidth / aspect, maxImageHeight) + 44
            let minHeight = columnHeights.min() ?? 0
            let column = columnHeights.firstIndex(of: minHeight) ?? 0
            columns[column].append(item)
            columnHeights[column] += itemHeight + spacing
        }

        return columns
    }

    private func parsedMediaAspectRatio(_ item: MediaItem) -> CGFloat {
        let raw = (item.exactResolution ?? item.resolutionLabel)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "X", with: "x")
        let parts = raw.split(separator: "x")
        guard parts.count == 2,
              let w = Double(parts[0]), w > 0,
              let h = Double(parts[1]), h > 0 else { return 1.6 }
        return min(max(CGFloat(w / h), 0.35), 3.6)
    }

    // MARK: - UI Components

    private func smartRetry() async {
        let query = viewModel.currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        switch workshopSourceManager.activeSource {
        case .wallpaperEngine:
            if !query.isEmpty {
                await viewModel.searchWorkshop(query: query)
            } else {
                await viewModel.loadWorkshopFeed()
            }
        case .dongtai:
            if !query.isEmpty {
                await viewModel.searchDongTai(query: query)
            } else {
                await viewModel.loadDongTaiFeed()
            }
        default:
            if !query.isEmpty {
                await viewModel.search(query: query)
            } else {
                await viewModel.loadHomeFeed()
            }
        }
    }

    private var emptyState: some View {
        Group {
            if let errorMessage = viewModel.errorMessage {
                ErrorStateView(
                    type: viewModel.networkStatus.connectionState == .offline ? .offline : .network,
                    message: errorMessage,
                    retryAction: { Task { await smartRetry() } }
                )
            } else {
                ErrorStateView(
                    type: .empty,
                    title: t("noMediaFilter"),
                    message: t("tryDifferentFilter"),
                    retryAction: { Task { await smartRetry() } }
                )
            }
        }
        .frame(height: 220)
        .exploreFrostedPanel(cornerRadius: 28, tint: exploreAtmosphere.tint.primary)
    }

    private var loadingState: some View {
        ExploreLoadingStateView(
            message: "加载中...",
            tint: arcSettings.primaryText
        )
        .exploreFrostedPanel(cornerRadius: 28, tint: exploreAtmosphere.tint.primary)
    }

    private var isMediaLoadingState: Bool {
        viewModel.items.isEmpty && (
            isInitialLoading
            || isFirstAppearance
            || viewModel.isLoading
            || viewModel.isLoadingMore
            || searchTask != nil
        )
    }

    private var loadMoreSentinel: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: MediaLoadMoreSentinelMinYPreferenceKey.self,
                value: proxy.frame(in: .named(Self.scrollCoordinateSpaceName)).minY
            )
        }
        .frame(height: 1)
    }

    // MARK: - Actions

    private func handleInitialLoad() async {

        if viewModel.items.isEmpty {
            isInitialLoading = true
        }
        await viewModel.initialLoadIfNeeded()
        if searchText.isEmpty {
            searchText = viewModel.currentQuery
        }
        syncAtmosphereIfNeeded()
        isInitialLoading = false
    }

    private func performFirstAppearanceLoad() async {

        isInitialLoading = true
        searchText = ""
        mediaSearchQuery = ""
        translationBridge.reset()
        selectedHotTag = nil
        selectedWorkshopTags = []
        selectedWorkshopType = .all
        selectedWorkshopContentLevel = .everyone
        selectedWorkshopResolution = nil
        selectedWorkshopSort = .trendWeek
        selectedCategory = .all
        selectedSort = .newest
        lastSyncedFirstItemID = nil
        loadMoreFailed = false
        viewModel.errorMessage = nil

        switch workshopSourceManager.activeSource {
        case .wallpaperEngine:
            await viewModel.loadWorkshopFeed()
        case .dongtai:
            await viewModel.loadDongTaiFeed()
        default:
            await viewModel.loadHomeFeed()
        }

        syncAtmosphereIfNeeded()
        isInitialLoading = false
        isFirstAppearance = false
    }

    private func selectCategory(_ category: MediaCategory) {
        prepareForFeedReplacement()
        withAnimation(AppFluidMotion.interactiveSpring) {
            selectedCategory = category
            selectedHotTag = nil
            selectedWorkshopTags = []
            selectedWorkshopType = .all
            selectedWorkshopContentLevel = .everyone
            searchText = ""
        }

        lastSyncedFirstItemID = nil
        // 清空 ViewModel 数据避免显示旧数据
        viewModel.clearItems()

        searchTask?.cancel()
        viewModel.isLoading = false
        searchTask = Task { @MainActor in
            defer { searchTask = nil }
            switch workshopSourceManager.activeSource {
            case .wallpaperEngine:
                await viewModel.loadWorkshopFeed()
            case .dongtai:
                await viewModel.loadDongTaiFeed()
            default:
                if category == .all {
                    await viewModel.loadHomeFeed()
                } else {
                    await viewModel.loadTagFeed(slug: category.slug, title: category.title)
                }
            }
        }
    }

    private func submitSearch(with query: String? = nil) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // BG 源：中文翻译处理（仅在无外部 query 时触发）
        let isMotionBG = workshopSourceManager.activeSource != .wallpaperEngine && workshopSourceManager.activeSource != .dongtai
        if query == nil && isMotionBG && !trimmed.isEmpty {
            let chineseDetected = translationBridge.isChinese(trimmed)
            let needsTranslation = chineseDetected
                && !translationBridge.translationDismissed
                && (translationBridge.translatedText == nil || translationBridge.translatedSourceText != trimmed)

            if needsTranslation {
                pendingSearchText = trimmed
                if translationBridge.checkCache(for: trimmed) {
                    pendingSearchText = nil
                    let effectiveQuery = translationBridge.effectiveQuery(for: trimmed)
                    mediaSearchQuery = effectiveQuery
                    executeSearch(query: effectiveQuery)
                    return
                }
                translationBridge.prepareForTranslation(trimmed)
                translationBridge.triggerTranslation()
                return
            }
        }

        let searchQuery = query ?? translationBridge.effectiveQuery(for: trimmed)
        if query != nil { searchText = "" }
        mediaSearchQuery = searchQuery
        pendingSearchText = nil
        executeSearch(query: searchQuery)
    }

    private func executeSearch(query: String) {
        prepareForFeedReplacement()
        selectedCategory = .all
        selectedHotTag = nil
        searchTask?.cancel()
        viewModel.isLoading = false
        searchTask = Task { @MainActor in
            defer {
                searchTask = nil
                syncAtmosphereIfNeeded()

            }
            switch workshopSourceManager.activeSource {
            case .wallpaperEngine:
                await applyWorkshopFilters(query: query)
            case .dongtai:
                await viewModel.searchDongTai(query: query)
            default:
                await viewModel.search(query: query)
            }
        }
    }

    private func handleTranslationCompleted() {
        guard workshopSourceManager.activeSource != .wallpaperEngine,
              workshopSourceManager.activeSource != .dongtai else { return }
        guard let pending = pendingSearchText else { return }
        pendingSearchText = nil
        let query = translationBridge.effectiveQuery(for: pending)
        mediaSearchQuery = query
        executeSearch(query: query)
    }

    private func handleFilterChange() {
        guard !isApplyingProgrammaticReset else { return }

        // Workshop/DongTai 模式下不支持标签过滤
        if workshopSourceManager.activeSource == .wallpaperEngine || workshopSourceManager.activeSource == .dongtai {
            syncAtmosphereIfNeeded()
            return
        }

        if let hotTag = selectedHotTag, hotTag.isServerSide,
           let slug = hotTag.serverSlug {
            prepareForFeedReplacement()
            Task {
                await viewModel.loadTagFeed(slug: slug, title: hotTag.title)
            }
            return
        }

        if selectedHotTag != nil && viewModel.items.isEmpty {
            Task {
                prepareForFeedReplacement()
                await viewModel.loadHomeFeed()
                await MainActor.run {
                    syncAtmosphereIfNeeded()
                }
            }
            return
        }

        syncAtmosphereIfNeeded()
    }

    private func handleWorkshopSortChange() {
        guard !isApplyingProgrammaticReset else { return }

        AppLogger.info(.wallpaper, "Workshop 排序变化", metadata: ["排序": selectedWorkshopSort.rawValue])
        // 仅在 Workshop 模式下实际重载数据；MotionBG 下仅更新 UI 不触发加载
        guard workshopSourceManager.activeSource == .wallpaperEngine else { return }
        prepareForFeedReplacement()
        searchTask?.cancel()
        viewModel.isLoading = false
        searchTask = Task { @MainActor in
            defer { searchTask = nil }
            await viewModel.setWorkshopSort(
                sortBy: selectedWorkshopSort.sortBy,
                days: selectedWorkshopSort.days
            )
        }
    }

    private func handleDongTaiSortChange() {
        guard !isApplyingProgrammaticReset else { return }

        guard workshopSourceManager.activeSource == .dongtai else { return }
        prepareForFeedReplacement()
        searchTask?.cancel()
        viewModel.isLoading = false
        searchTask = Task { @MainActor in
            defer {
                searchTask = nil
                // 强制刷新网格（DongTai 查询为同步操作）
                syncAtmosphereIfNeeded()

            }
            await viewModel.setDongTaiSort(sortBy: selectedDongTaiSort)
        }
    }

    private func handleSourceChange() {
        // 数据源切换时重置并重新加载
        resetAllFilters(reloadData: true)
    }

    private func handleWorkshopURLSubmit() {
        let url = workshopURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            workshopURLError = "请输入链接"
            return
        }
        isResolvingWorkshopURL = true
        workshopURLError = nil
        Task {
            do {
                let isWE = WorkshopService.extractWorkshopID(from: url) != nil
                let isDongTai = DynamicWallpaperService.shared.canHandleOSSURL(url)
                let item: MediaItem
                if isWE {
                    item = try await viewModel.resolveWorkshopItemByURL(url)
                } else if isDongTai {
                    item = try await viewModel.resolveDongTaiItemByURL(url)
                } else {
                    item = try await viewModel.resolveMotionBGItemByURL(url)
                }
                await MainActor.run {
                    isResolvingWorkshopURL = false
                    showWorkshopURLSheet = false
                    workshopURLInput = ""
                    selectedMedia = item
                }
            } catch {
                await MainActor.run {
                    isResolvingWorkshopURL = false
                    workshopURLError = error.localizedDescription
                }
            }
        }
    }

    private func triggerLoadMore() {
        guard viewModel.hasMorePages,
              !viewModel.isLoading,
              !isLoadingMore,
              !viewModel.isLoadingMore else { return }

        isLoadingMore = true
        loadMoreFailed = false
        loadMoreTask?.cancel()
        loadMoreTask = Task {
            switch workshopSourceManager.activeSource {
            case .wallpaperEngine:
                await viewModel.loadMoreWorkshop()
            case .dongtai:
                await viewModel.loadMoreDongTai()
            default:
                await viewModel.loadMore()
            }
            await MainActor.run {
                if viewModel.hasMorePages && viewModel.errorMessage != nil {
                    loadMoreFailed = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isLoadingMore = false
                }
            }
            loadMoreTask = nil
        }
    }

    private func handleLoadMoreSentinelPosition(_ sentinelMinY: CGFloat, viewportHeight: CGFloat) {
        guard isVisible, viewportHeight > 0, sentinelMinY.isFinite else { return }
        if sentinelMinY <= viewportHeight + Self.loadMoreTriggerThreshold {
            triggerLoadMore()
        }
    }

    private func resetAllFilters(reloadData: Bool = false) {
        isApplyingProgrammaticReset = true
        searchText = ""
        mediaSearchQuery = ""
        translationBridge.reset()
        selectedHotTag = nil
        selectedWorkshopTags = []
        selectedWorkshopType = .all
        selectedWorkshopContentLevel = .everyone
        selectedWorkshopResolution = nil
        selectedWorkshopSort = .trendWeek
        selectedDongTaiCategories = []
        selectedDongTaiListType = .all
        selectedDongTaiSort = .popular
        dongtaiFilterAudio = nil
        dongtaiFilterFourK = nil
        selectedCategory = .all
        selectedSort = .newest
        lastSyncedFirstItemID = nil
        loadMoreFailed = false
        viewModel.errorMessage = nil
        prepareForFeedReplacement()

        if reloadData {
            reloadDefaultFeedAfterReset()
        } else {
            Task { @MainActor in
                await Task.yield()
                isApplyingProgrammaticReset = false
            }
        }
    }

    private func reloadDefaultFeedAfterReset() {
        searchTask?.cancel()
        loadMoreTask?.cancel()

        pendingSearchText = nil
        isLoadingMore = false
        isInitialLoading = viewModel.items.isEmpty

        searchTask = Task { @MainActor in
            defer {
                isInitialLoading = false
                isApplyingProgrammaticReset = false
                searchTask = nil
            }

            switch workshopSourceManager.activeSource {
            case .wallpaperEngine:
                await viewModel.resetAndLoadDefaultWorkshopFeed()
            case .dongtai:
                await viewModel.resetAndLoadDefaultDongTaiFeed()
            default:
                await viewModel.resetAndLoadDefaultHomeFeed()
            }

            syncAtmosphereIfNeeded()

        }
    }

    private func prepareForFeedReplacement() {
        loadMoreTask?.cancel()
        sentinelDebounceTask?.cancel()
        isLoadingMore = false
        loadMoreFailed = false
        showScrollToTop = false
        outerScrollToTopToken &+= 1
    }

    private func cancelTasks() {
        searchTask?.cancel()
        loadMoreTask?.cancel()
        sentinelDebounceTask?.cancel()

        searchTask = nil
        loadMoreTask = nil
        sentinelDebounceTask = nil
    }

    private func syncAtmosphereIfNeeded() {
        let items = viewModel.items
        let newFirstID = items.first?.id
        guard newFirstID != lastSyncedFirstItemID else { return }
        lastSyncedFirstItemID = newFirstID
        DispatchQueue.main.async {
            guard lastSyncedFirstItemID == newFirstID else { return }
            exploreAtmosphere.updateFirstMedia(items.first)
        }
    }

    private func randomizeAtmosphere() {
        guard !viewModel.items.isEmpty else { return }
        let random = viewModel.items.randomElement()!
        exploreAtmosphere.updateFromImageURL(
            random.coverImageURL,
            keyPrefix: "rand-media"
        )
    }

    private func formattedCount(_ count: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    }

}

private func formatCompactCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000)
    }
    return "\(count)"
}

// MARK: - Models & Enums

private enum MediaSortOption: String, CaseIterable, SortOptionProtocol {
    case newest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return t("sort.newest")
        }
    }

    var menuTitle: String {
        switch self {
        case .newest: return t("sortByNewest")
        }
    }
}

private enum MediaHotTag: String, CaseIterable, Identifiable {
    case anime
    case rain
    case cyberpunk
    case nature
    case game
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anime: return t("filter.anime")
        case .rain: return t("filter.rain")
        case .cyberpunk: return t("filter.cyberpunk")
        case .nature: return t("filter.nature2")
        case .game: return t("filter.game")
        case .dark: return t("filter.dark")
        }
    }

    var isServerSide: Bool {
        serverSlug != nil
    }

    var serverSlug: String? {
        switch self {
        case .anime: return "anime"
        case .rain: return "rain"
        case .cyberpunk: return "cyberpunk"
        case .nature: return "nature"
        case .game: return "games"
        case .dark: return "dark"
        }
    }
}

private enum MediaCategory: String, CaseIterable, Identifiable {
    case all, anime, games, superhero, nature, car, tv, fantasy, space
    case technology, holiday, animal, horror, football, japan, helloKitty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return t("filter.all")
        case .anime: return t("filter.anime")
        case .games: return t("filter.games")
        case .superhero: return t("filter.superhero")
        case .nature: return t("filter.nature2")
        case .car: return t("filter.car")
        case .tv: return t("filter.tv")
        case .fantasy: return t("filter.fantasy")
        case .space: return t("filter.space")
        case .technology: return t("filter.technology2")
        case .holiday: return t("filter.holiday")
        case .animal: return t("filter.animal")
        case .horror: return t("filter.horror")
        case .football: return t("filter.football")
        case .japan: return t("filter.japan")
        case .helloKitty: return "Hello Kitty"
        }
    }

    var slug: String {
        switch self {
        case .all: return ""
        case .helloKitty: return "hello-kitty"
        default: return rawValue
        }
    }

    var icon: String {
        switch self {
        case .all: return "sparkles"
        case .anime: return "person.crop.rectangle.stack.fill"
        case .games: return "gamecontroller.fill"
        case .superhero: return "bolt.shield.fill"
        case .nature: return "leaf.fill"
        case .car: return "car.side.fill"
        case .tv: return "film.stack.fill"
        case .fantasy: return "wand.and.stars"
        case .space: return "sparkles.tv"
        case .technology: return "cpu.fill"
        case .holiday: return "gift.fill"
        case .animal: return "pawprint.fill"
        case .horror: return "moon.stars.fill"
        case .football: return "soccerball"
        case .japan: return "building.columns.fill"
        case .helloKitty: return "heart.fill"
        }
    }

    var accentColors: [String] {
        switch self {
        case .all: return ["5A7CFF", "20C1FF"]
        case .anime: return ["FF88C7", "7747FF"]
        case .games: return ["62D4FF", "4E66FF"]
        case .superhero: return ["FFB15B", "E14949"]
        case .nature: return ["98E978", "3AA565"]
        case .car: return ["FFD66E", "FF8B3D"]
        case .tv: return ["63A3FF", "6D42FF"]
        case .fantasy: return ["F17CF5", "5F67FF"]
        case .space: return ["B1C9FF", "5B75FF"]
        case .technology: return ["4FF4D6", "1AB9A5"]
        case .holiday: return ["FF6B6B", "EE5A6E"]
        case .animal: return ["C8A876", "8B7355"]
        case .horror: return ["8B0000", "4A0000"]
        case .football: return ["4CAF50", "2E7D32"]
        case .japan: return ["FFB7C5", "E85D75"]
        case .helloKitty: return ["FF69B4", "FF1493"]
        }
    }
}

private struct WorkshopActiveFilterChip: View {
    let title: String
    let accentHex: String
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: "#\(accentHex)")).frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ArcBackgroundSettings.shared.primaryText.opacity(0.94))
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(isHovered ? 0.95 : 0.72))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    Capsule(style: .continuous).fill(.ultraThinMaterial)
                    Capsule(style: .continuous).fill(Color(hex: "#\(accentHex)").opacity(0.12))
                }
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(hex: "#\(accentHex)").opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .onHover { isHovered = $0 }
    }
}


// MARK: - Workshop 排序选项

private enum WorkshopSortOption: String, CaseIterable, SortOptionProtocol {
    case trendToday = "trend_1"
    case trendWeek = "trend_7"
    case trendMonth = "trend_30"
    case trendQuarter = "trend_90"
    case trendYear = "trend_365"
    case trendAll = "trend"
    case updated = "updated"
    case created = "created"
    case topRated = "toprated"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trendToday: return t("workshop.sort.trendToday")
        case .trendWeek: return t("workshop.sort.trendWeek")
        case .trendMonth: return t("workshop.sort.trendMonth")
        case .trendQuarter: return t("workshop.sort.trendQuarter")
        case .trendYear: return t("workshop.sort.trendYear")
        case .trendAll: return t("workshop.sort.trendAll")
        case .updated: return t("workshop.sort.updated")
        case .created: return t("workshop.sort.created")
        case .topRated: return t("workshop.sort.topRated")
        }
    }

    var menuTitle: String { title }

    /// 映射到 WorkshopSearchParams.SortOption
    var sortBy: WorkshopSearchParams.SortOption {
        switch self {
        case .trendToday, .trendWeek, .trendMonth, .trendQuarter, .trendYear, .trendAll:
            return .ranked
        case .updated:
            return .updated
        case .created:
            return .created
        case .topRated:
            return .topRated
        }
    }

    /// 时间范围（仅对热门趋势有效），nil = 全部时间
    var days: Int? {
        switch self {
        case .trendToday: return 1
        case .trendWeek: return 7
        case .trendMonth: return 30
        case .trendQuarter: return 90
        case .trendYear: return 365
        case .trendAll, .updated, .created, .topRated:
            return nil
        }
    }
}

// MARK: - Workshop URL 输入按钮

struct WorkshopURLInputButton: View {
    let tint: Color
    let action: () -> Void
    @ObservedObject private var arcSettings = ArcBackgroundSettings.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "link")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(arcSettings.primaryText.opacity(0.92))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
                .arcFrostedCircle(
                    intensity: arcSettings.frostedIntensity,
                    isLightMode: arcSettings.isLightMode,
                    accentColor: tint
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .onHover { isHovered = $0 }
        .help("通过链接打开壁纸")
    }
}

// MARK: - Workshop URL 输入弹窗

struct WorkshopURLInputSheet: View {
    @Binding var urlInput: String
    let errorMessage: String?
    let isLoading: Bool
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("通过链接打开壁纸")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            // Input
            VStack(alignment: .leading, spacing: 8) {
                TextField("粘贴壁纸链接...", text: $urlInput, axis: .vertical)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.9))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.1), lineWidth: 1)
                    )
                    .focused($isInputFocused)
                    .onSubmit {
                        if !isLoading { onSubmit() }
                    }

                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red.opacity(0.8))
                        .transition(.opacity)
                }

                Text("支持格式：steamcommunity.com/sharedfiles/filedetails/?id=1234567890 或 motionbgs.com/xxx")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            }

            // Buttons
            HStack(spacing: 12) {
                Button(action: onDismiss) {
                    Text("取消")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)

                Button(action: onSubmit) {
                    HStack(spacing: 6) {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.8)
                        }
                        Text("确认")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.35))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isLoading || urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(
            DarkLiquidGlassBackground(cornerRadius: 16, isHovered: false)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isInputFocused = true
            }
        }
    }
}

//
