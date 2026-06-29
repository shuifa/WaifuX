import SwiftUI
import Kingfisher

struct AddToFolderSheetView: View {
    let contentType: ContentType
    let subTab: MyLibraryContentView.SubTab
    let availableWallpapers: [(id: String, name: String, thumbURL: URL?, localFileURL: URL?)]
    let availableMedia: [(id: String, name: String, thumbURL: URL?)]
    let onAdd: ([String]) -> Void
    let onDismiss: () -> Void

    @State private var selectedIDs = Set<String>()
    @State private var searchQuery = ""

    private var filteredWallpapers: [(id: String, name: String, thumbURL: URL?, localFileURL: URL?)] {
        guard !searchQuery.isEmpty else { return availableWallpapers }
        let q = searchQuery.lowercased()
        return availableWallpapers.filter { $0.name.lowercased().contains(q) }
    }

    private var filteredMedia: [(id: String, name: String, thumbURL: URL?)] {
        guard !searchQuery.isEmpty else { return availableMedia }
        let q = searchQuery.lowercased()
        return availableMedia.filter { $0.name.lowercased().contains(q) }
    }

    private var currentCount: Int {
        contentType == .wallpaper ? filteredWallpapers.count : filteredMedia.count
    }

    private let columns = [
        GridItem(.fixed(130), spacing: 10),
        GridItem(.fixed(130), spacing: 10),
        GridItem(.fixed(130), spacing: 10),
        GridItem(.fixed(130), spacing: 10)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("add.to.folder"))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Text(String(format: t("items.not.in.folder"), currentCount))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Button {
                    let allIDs = Set(currentItems.map { $0.id })
                    if selectedIDs == allIDs {
                        selectedIDs = []
                    } else {
                        selectedIDs = allIDs
                    }
                } label: {
                    Text(selectedIDs.count == currentCount && !currentItems.isEmpty
                         ? t("deselect.all") : t("select.all"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 12)

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                TextField(t("search.placeholder"), text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()
                .background(Color.white.opacity(0.1))

            // Grid
            if currentCount == 0 {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.3))
                    Text(searchQuery.isEmpty ? t("no.items.to.add") : t("search.no.results"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        if contentType == .wallpaper {
                            ForEach(filteredWallpapers, id: \.id) { item in
                                wallpaperPickerCard(item: item)
                            }
                        } else {
                            ForEach(filteredMedia, id: \.id) { item in
                                mediaPickerCard(item: item)
                            }
                        }
                    }
                    .padding(16)
                }
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // Bottom bar
            HStack {
                Text(String(format: t("selected.count"), selectedIDs.count))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))

                Spacer()

                Button(t("cancel")) {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

                Button {
                    onAdd(Array(selectedIDs))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text(String(format: t("add.n.items"), selectedIDs.count))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selectedIDs.isEmpty
                                  ? Color.white.opacity(0.05)
                                  : Color.accentColor.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(selectedIDs.isEmpty
                                    ? Color.white.opacity(0.05)
                                    : Color.accentColor.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                                .disabled(selectedIDs.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 600, height: 520)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: "1C1C1E"))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    // MARK: - Picker Cards

    private func wallpaperPickerCard(item: (id: String, name: String, thumbURL: URL?, localFileURL: URL?)) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        return Button {
            if isSelected {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
        } label: {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    // Thumbnail: prefer local file, fallback to remote URL
                    let resolvedURL: URL? = {
                        if let local = item.localFileURL, local.isFileURL {
                            return local
                        }
                        return item.thumbURL
                    }()

                    KFImage(resolvedURL)
                        .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 256, height: 256)))
                        .cacheMemoryOnly(false)
                        .placeholder { _ in
                            Color.gray.opacity(0.2)
                        }
                        .resizable()
                        .scaledToFill()
                        .frame(width: 130, height: 90)
                        .clipped()

                    // Selection indicator
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(isSelected ? Color.accentColor : .white.opacity(0.6))
                        .padding(6)
                        .background(
                            Circle()
                                .fill(.black.opacity(0.4))
                        )
                        .padding(5)
                }

                // Name
                Text(item.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .frame(width: 130, alignment: .leading)
                    .background(Color.black.opacity(0.3))
            }
            .frame(width: 130)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.1),
                            lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
            }

    private func mediaPickerCard(item: (id: String, name: String, thumbURL: URL?)) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        return Button {
            if isSelected {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
        } label: {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    KFImage(item.thumbURL)
                        .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 256, height: 256)))
                        .cacheMemoryOnly(false)
                        .placeholder { _ in
                            Color.gray.opacity(0.2)
                        }
                        .resizable()
                        .scaledToFill()
                        .frame(width: 130, height: 90)
                        .clipped()

                    // Video badge
                    Image(systemName: "video.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(4)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Capsule())
                        .padding(.leading, 6)
                        .padding(.bottom, 6)
                        .frame(width: 130, height: 90, alignment: .bottomLeading)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(isSelected ? Color.accentColor : .white.opacity(0.6))
                        .padding(6)
                        .background(
                            Circle()
                                .fill(.black.opacity(0.4))
                        )
                        .padding(5)
                }

                Text(item.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .frame(width: 130, alignment: .leading)
                    .background(Color.black.opacity(0.3))
            }
            .frame(width: 130)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.1),
                            lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
            }

    // MARK: - Helpers

    private var currentItems: [(id: String, name: String)] {
        if contentType == .wallpaper {
            return filteredWallpapers.map { (id: $0.id, name: $0.name) }
        } else {
            return filteredMedia.map { (id: $0.id, name: $0.name) }
        }
    }
}
