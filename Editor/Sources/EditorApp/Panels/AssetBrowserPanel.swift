import Foundation
import EditorCore
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import EngineKernel
import AssetPipeline

/// Content Browser — the editor's asset panel, modeled after Unreal's. A
/// toolbar (import + live search + item count), a breadcrumb bar with a
/// grid/list toggle, and a scrollable, reflowing folder hierarchy. Asset tiles
/// support modifier-based multi-selection, keyboard navigation, drag-to-drop,
/// and grouped scene insertion. Imports target the folder currently being viewed.
struct AssetBrowserPanel: View {
    let app: EditorApplication

    @State private var searchText: String = ""
    @AppStorage("assetBrowser.viewMode") private var viewMode: AssetViewMode = .grid
    @AppStorage("assetBrowser.sortMode") private var sortMode: AssetSortMode = .nameAscending
    @AppStorage("assetBrowser.categoryFilter") private var categoryFilter: AssetCategoryFilter = .all
    @State private var selection = AssetBrowserSelectionModel()
    @State private var reloadStatusMessage: String? = nil
    @State private var reloadStatusIsError: Bool = false
    /// Relative folder path currently shown ("" == project root). Uses "/" as
    /// separator, matching `AssetRegistryEntry.relativePath`.
    @State private var currentFolder: String = ""
    @State private var lastNavigationRevision: UInt64 = 0
    @State private var previewAssetID: String? = nil
    @State private var editingAsset: EditorAsset? = nil
    @State private var assetEditPath = ""
    @State private var referenceLocations: [EditorAssetReferenceLocation] = []
    @State private var showsReferences = false
    @State private var missingPath: String? = nil
    @State private var referenceFilePath: String? = nil
    @State private var showsMissingResources = false

    private func importAssets() {
        EditorAssetImportCoordinator.requestImport(app: app, into: currentFolder)
    }

    private func reloadAssets() {
        let result = app.reloadAssets()
        AssetThumbnailRasterizer.invalidate()
        ImageAssetRegistryHolder.current?.clear()
        if let count = result {
            reloadStatusMessage = String(format: L("Reloaded %lld assets."), Int64(count))
            reloadStatusIsError = false
        } else {
            reloadStatusMessage = L("Asset reload failed. See Console for details.")
            reloadStatusIsError = true
        }
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func searchMatches(_ assets: [EditorAsset]) -> [EditorAsset] {
        let query = trimmedQuery
        guard !query.isEmpty else { return assets }
        return assets.filter {
            $0.name.range(of: query, options: .caseInsensitive) != nil
                || $0.relativePath.range(of: query, options: .caseInsensitive) != nil
        }
    }

    private func navigate(to folder: String) {
        currentFolder = folder
        selection.clear()
    }

    var body: some View {
        StoreScope(app.store) { store in
            let _ = store.presentationRevision
            let allAssets = EditorAssetCatalog.entries()
            let _: Void = applyNavigation(store, assets: allAssets)
            let isSearching = !trimmedQuery.isEmpty
            let categoryAssets = AssetBrowserOrdering.filter(allAssets, category: categoryFilter)
            let unfilteredListing = AssetFolderListing.make(folder: currentFolder, from: allAssets)
            // While searching, ignore folder structure and show flat matches
            // across the whole project (Unreal's search behaviour).
            let unsortedListing = isSearching
                ? AssetFolderListing(folders: [], assets: searchMatches(categoryAssets))
                : AssetFolderListing.make(folder: currentFolder, from: categoryAssets)
            let listing = unsortedListing.sorted(by: sortMode)
            let itemCount = listing.folders.count + listing.assets.count
            let countTotal = isSearching
                ? categoryAssets.count
                : unfilteredListing.folders.count + unfilteredListing.assets.count
            let isFiltering = isSearching || categoryFilter != .all
            let visibleAssetIDs = listing.assets.map(\.id)
            let selectedAssets = listing.assets.filter { selection.selectedIDs.contains($0.id) }

            Box(direction: .column, alignItems: .stretch) {
                AssetBrowserToolbar(searchText: $searchText,
                                    totalCount: countTotal,
                                    visibleCount: itemCount,
                                    isFiltering: isFiltering,
                                    onImport: { importAssets() },
                                    onReload: { reloadAssets() })

                Divider()

                AssetBreadcrumbBar(rootName: rootName,
                                   currentFolder: currentFolder,
                                   isSearching: isSearching,
                                   viewMode: $viewMode,
                                   sortMode: $sortMode,
                                   categoryFilter: $categoryFilter,
                                   onNavigate: { navigate(to: $0) })
                    .padding(horizontal: 10, vertical: 5)

                Divider()

                if let reloadStatusMessage {
                    Text(reloadStatusMessage)
                        .font(.caption)
                        .foregroundColor(reloadStatusIsError ? .error : .success)
                        .padding(horizontal: 10, vertical: 5)
                    Divider()
                }

                if hasWorkflowDetails {
                    ScrollView(.vertical, scrollbarGutter: .stable) {
                        assetWorkflowDetails(allAssets).frame(width: .percent(100))
                    }.flex().debugName("asset-workflow-scroll")
                } else {
                    content(allAssets: allAssets,
                            listing: listing,
                            isSearching: isSearching,
                            visibleAssetIDs: visibleAssetIDs)
                }

                if !selectedAssets.isEmpty && !hasWorkflowDetails {
                    Divider()
                    AssetSelectionBar(
                        assets: selectedAssets,
                        isAddEnabled: store.playbackState == .stopped,
                        onAddToScene: {
                            _ = app.spawnAssets(selectedAssets)
                        },
                        onReveal: {
                            revealAssets(selectedAssets)
                        }
                    )
                }
                Row(alignment: .center, spacing: 6) {
                    Button(L("Missing Resources"), isSelected: showsMissingResources) {
                        showsMissingResources.toggle()
                    }.buttonStyle(.ghost).controlSize(.small).debugName("asset-missing-resources")
                    Spacer(minLength: 0)
                }.padding(horizontal: 6, vertical: 2)
            }
            .frame(minWidth: 240)
        }
    }

    private var rootName: String {
        let name = URL(fileURLWithPath: app.projectDirectory, isDirectory: true).lastPathComponent
        return name.isEmpty ? L("Content") : name
    }

    @ViewBuilder
    private func content(allAssets: [EditorAsset],
                         listing: AssetFolderListing,
                         isSearching: Bool,
                         visibleAssetIDs: [String]) -> some View {
        if allAssets.isEmpty {
            ScrollView(.vertical, scrollbarGutter: .stable) {
                AssetBrowserEmptyState(projectDirectory: app.projectDirectory,
                                       onImport: { importAssets() })
                    .frame(width: .percent(100))
            }.flex().debugName("asset-empty-scroll")
        } else if listing.folders.isEmpty && listing.assets.isEmpty {
            if isSearching {
                placeholder(title: L("No matching assets"), subtitle: "\"\(trimmedQuery)\"")
            } else if categoryFilter != .all {
                placeholder(title: L("No matching assets"),
                            subtitle: categoryFilter == .meshes ? L("Meshes") : L("Textures"))
            } else {
                placeholder(title: L("This folder is empty"), subtitle: currentFolder)
            }
        } else {
            if viewMode == .list {
                let rows = listing.folders.map { AssetListingRow.folder($0) } + listing.assets.map { AssetListingRow.asset($0) }
                VirtualStack(rows, id: \.id, rowHeight: 46, spacing: 2) { row in
                    switch row {
                    case .folder(let folder):
                        AssetFolderListRow(name: folder.name, onOpen: { navigate(to: folder.path) })
                            .contextMenu([.item(MenuItem(id: "open", title: L("Open"), action: { navigate(to: folder.path) }))])
                    case .asset(let asset):
                        AssetListRow(asset: asset, app: app,
                                     isSelected: selection.selectedIDs.contains(asset.id),
                                     onSelect: { selectAsset(asset.id, modifiers: $0, visibleIDs: visibleAssetIDs) },
                                     onNavigate: { navigateSelection(from: asset.id, direction: $0, modifiers: $1, visibleIDs: visibleAssetIDs) },
                                     onSelectAll: { selection.selectAll(in: visibleAssetIDs) },
                                     onClearSelection: { selection.clear() }, onActivate: { activateAsset(asset) })
                            .contextMenu(onOpen: { selectContextAsset(asset.id, visibleIDs: visibleAssetIDs) }, entries: { assetContextEntries(asset, visibleAssets: listing.assets) })
                    }
                }
                .padding(horizontal: 6, vertical: 6)
                .flex()
            } else {
                ScrollView(.vertical, scrollbarGutter: .stable) {
                    Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 10) {
                        for folder in listing.folders {
                            AssetFolderTile(name: folder.name, onOpen: { navigate(to: folder.path) })
                        }
                        listing.assets.map { gridAsset($0, visibleIDs: visibleAssetIDs, visibleAssets: listing.assets) }

                    }.padding(horizontal: 10, vertical: 10)
                }.flex()
            }
        }
    }

    private func placeholder(title: String, subtitle: String) -> some View {
        ScrollView(.vertical, scrollbarGutter: .stable) {
            AssetBrowserPlaceholder(title: title, subtitle: subtitle).frame(width: .percent(100))
        }.flex()
    }

    private func gridAsset(_ asset: EditorAsset, visibleIDs: [String], visibleAssets: [EditorAsset]) -> AnyView {
        AnyView(AssetTile(asset: asset, app: app,
                                      isSelected: selection.selectedIDs.contains(asset.id),
                                      onSelect: { selectAsset(asset.id, modifiers: $0, visibleIDs: visibleIDs) },
                                      onNavigate: { navigateSelection(from: asset.id, direction: $0, modifiers: $1, visibleIDs: visibleIDs) },
                                      onSelectAll: { selection.selectAll(in: visibleIDs) },
                                      onClearSelection: { selection.clear() }, onActivate: { activateAsset(asset) })
                                .contextMenu(onOpen: { selectContextAsset(asset.id, visibleIDs: visibleIDs) }, entries: { assetContextEntries(asset, visibleAssets: visibleAssets) }))
    }

    private func selectContextAsset(_ id: String, visibleIDs: [String]) {
        if !selection.selectedIDs.contains(id) { selectAsset(id, modifiers: [], visibleIDs: visibleIDs) }
    }

    private func assetContextEntries(_ target: EditorAsset, visibleAssets: [EditorAsset]) -> [MenuEntry] {
        let selected = visibleAssets.filter { selection.selectedIDs.contains($0.id) }
        let assets = selected.isEmpty ? [target] : selected
        return [
            .item(MenuItem(id: "open", title: L("Open"), action: { activateAsset(target) })),
            .item(MenuItem(id: "asset-rename", title: L("Rename"), isEnabled: app.store.playbackState == .stopped,
                action: { beginRelocation(target) })),
            .item(MenuItem(id: "asset-move", title: L("Move"), isEnabled: app.store.playbackState == .stopped,
                action: { beginRelocation(target) })),
            .item(MenuItem(id: "asset-references", title: L("Find References"), action: {
                referenceLocations = app.assetReferences(target); showsReferences = true
            })),
            .item(MenuItem(id: "asset-add", title: L("Add to Scene"),
                           isEnabled: assets.contains { $0.kind.isMesh } && app.store.state.timing.playbackState == .stopped,
                           action: { _ = app.spawnAssets(assets) })),
            .item(MenuItem(id: "asset-reveal", title: L("Reveal"), action: { revealAssets(assets) })),
            .item(MenuItem(id: "copy-path", title: L("Copy Path"), action: {
                ClipboardHolder.write?(assets.map(\.relativePath).joined(separator: "\n"))
            })),
            .separator("asset-refresh"),
            .item(MenuItem(id: "asset-reload", title: L("Reload"), action: reloadAssets)),
        ]
    }

    private func selectAsset(_ assetID: String,
                             modifiers: KeyModifiers,
                             visibleIDs: [String]) {
        var next = selection
        next.select(assetID, in: visibleIDs, modifiers: modifiers)
        selection = next
    }

    private func navigateSelection(from assetID: String,
                                   direction: Int,
                                   modifiers: KeyModifiers,
                                   visibleIDs: [String]) {
        guard let nextID = AssetBrowserSelectionModel.adjacentAssetID(
            from: assetID,
            in: visibleIDs,
            direction: direction
        ) else { return }
        AssetBrowserFocusRegistry.focus(nextID)
        selectAsset(nextID, modifiers: modifiers, visibleIDs: visibleIDs)
    }

    private func activateAsset(_ asset: EditorAsset) {
        previewAssetID = asset.id
    }

    private func applyNavigation(_ store: EditorStore, assets: [EditorAsset]) {
        guard lastNavigationRevision != store.assetNavigationRevision else { return }
        lastNavigationRevision = store.assetNavigationRevision
        guard let id = store.assetNavigationID else { return }
        searchText = ""; categoryFilter = .all
        referenceFilePath = nil
        if let asset = assets.first(where: { $0.id == id || $0.absolutePath == id || $0.relativePath == id }) {
            currentFolder = (asset.relativePath as NSString).deletingLastPathComponent
            if currentFolder == "." { currentFolder = "" }
            var next = AssetBrowserSelectionModel()
            next.select(asset.id, in: assets.map(\.id), modifiers: [])
            selection = next; previewAssetID = asset.id; missingPath = nil
        } else {
            let root = URL(fileURLWithPath: app.projectDirectory, isDirectory: true)
            let url = (id as NSString).isAbsolutePath ? URL(fileURLWithPath: id) : root.appendingPathComponent(id)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                let folder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
                if let relative = EditorAssetFileWorkflow.projectRelativePath(folder, within: root) {
                    currentFolder = relative
                }
                missingPath = nil; previewAssetID = nil
                if !isDirectory.boolValue { referenceFilePath = url.path }
            } else {
                missingPath = url.path
            }
        }
    }

    private func beginRelocation(_ asset: EditorAsset) {
        editingAsset = asset; assetEditPath = asset.relativePath
    }

    private func repair(_ path: String) {
        guard let display = AppDisplayHandleHolder.current else { return }
        MainActor.assumeIsolated {
            display.requestOpenFile(filters: [(name: L("Replacement Resource"), extensions: [(path as NSString).pathExtension])],
                                    allowsMultiple: false, defaultPath: app.projectDirectory) { paths in
                guard let replacement = paths.first else { return }
                if app.repairMissingAsset(at: path, from: URL(fileURLWithPath: replacement)) {
                    AssetThumbnailRasterizer.invalidate(); ImageAssetRegistryHolder.current?.clear()
                    missingPath = nil
                }
            }
        }
    }

    private var hasWorkflowDetails: Bool {
        editingAsset != nil || previewAssetID != nil || showsReferences
            || missingPath != nil || referenceFilePath != nil || showsMissingResources
    }

    private func closeWorkflowDetails() {
        editingAsset = nil
        previewAssetID = nil
        showsReferences = false
        missingPath = nil
        referenceFilePath = nil
        showsMissingResources = false
    }

    private func assetWorkflowDetails(_ assets: [EditorAsset]) -> some View {
        Box(direction: .column, alignItems: .stretch, spacing: 6) {
            Row(alignment: .center, spacing: 6) {
                Spacer(minLength: 0)
                Button(L("Close"), action: closeWorkflowDetails).buttonStyle(.ghost)
                    .debugName("asset-workflow-close")
            }
            if let asset = editingAsset {
                Text(L("Rename or Move: project-relative destination")).font(.caption).foregroundColor(.onSurfaceVariant)
                Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 6) {
                    TextField(L("New project-relative path"), text: $assetEditPath,
                        focusRequestID: "asset-path-" + asset.id, onSubmit: {
                            if app.relocateAsset(asset, to: assetEditPath) { editingAsset = nil; AssetThumbnailRasterizer.invalidate() }
                        }).frame(minWidth: 160).flex()
                    Button(L("Apply")) {
                        if app.relocateAsset(asset, to: assetEditPath) { editingAsset = nil; AssetThumbnailRasterizer.invalidate() }
                    }.buttonStyle(.primary)
                    Button(L("Cancel")) { editingAsset = nil }.buttonStyle(.ghost)
                }
            }
            if let asset = assets.first(where: { $0.id == previewAssetID }) {
                Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
                    AssetThumbnail(asset: asset).frame(width: 144, height: 120)
                    Column(alignment: .leading, spacing: 4) {
                        Text(asset.name, lineLimit: 1).font(.label)
                        Text(asset.relativePath, lineLimit: 2).font(.caption).foregroundColor(.onSurfaceVariant)
                        Button(L("Find References")) {
                            referenceLocations = app.assetReferences(asset); showsReferences = true
                        }.buttonStyle(.ghost)
                        Button(L("Rename / Move"), isEnabled: app.store.playbackState == .stopped) { beginRelocation(asset) }.buttonStyle(.ghost)
                    }.frame(minWidth: 160).flex()
                    Button(L("Close")) { previewAssetID = nil }.buttonStyle(.ghost)
                }
            }
            if showsReferences {
                Row(alignment: .center, spacing: 6) {
                    Text("\(L("References")) \(referenceLocations.count)").font(.label).flex()
                    Button(L("Close")) { showsReferences = false }.buttonStyle(.ghost)
                }
                Box(direction: .column, alignItems: .stretch, spacing: 2) {
                    referenceLocations.map { reference in
                        Button(reference.label) { app.navigateToIssue(reference.target) }.buttonStyle(.ghost)
                    }
                    if referenceLocations.isEmpty { Text(L("No references found")).font(.caption) }
                }
            }
            if let missingPath {
                Row(alignment: .center, spacing: 6) {
                    Text(missingPath, lineLimit: 2).font(.caption).foregroundColor(.warning).flex()
                    Button(L("Repair Missing Resource"), isEnabled: app.store.playbackState == .stopped) { repair(missingPath) }.buttonStyle(.ghost)
                    Button(L("Close")) { self.missingPath = nil }.buttonStyle(.ghost)
                }
            }
            if let path = referenceFilePath {
                Row(alignment: .center, spacing: 6) {
                    Text(path, lineLimit: 2).font(.caption).foregroundColor(.onSurfaceVariant).flex()
                    Button(L("Reveal in Finder")) { revealPaths([path]) }.buttonStyle(.ghost)
                    Button(L("Close")) { referenceFilePath = nil }.buttonStyle(.ghost)
                }
            }
            if showsMissingResources {
                let paths = app.missingAssetPaths()
                Box(direction: .column, alignItems: .stretch, spacing: 2) {
                    paths.map { path in
                        Button(path) { missingPath = path }.buttonStyle(.ghost)
                    }
                    if paths.isEmpty { Text(L("No missing resources")).font(.caption).foregroundColor(.onSurfaceVariant) }
                }
            }
        }.padding(6)
    }

    private func revealAssets(_ assets: [EditorAsset]) {
        revealPaths(assets.map(\.absolutePath))
    }

    private func revealPaths(_ paths: [String]) {
        let validPaths = paths.filter {
            FileManager.default.fileExists(atPath: $0)
        }
        guard !validPaths.isEmpty else {
            app.logConsole("Could not reveal selected assets",
                           severity: .error,
                           detail: "The source files no longer exist. Reload the Asset Browser.")
            return
        }
        let process = Process()
        #if os(macOS)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-R"] + validPaths
        #elseif os(Windows)
        process.executableURL = URL(fileURLWithPath: "C:/Windows/explorer.exe")
        process.arguments = ["/select,", validPaths[0]]
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [URL(fileURLWithPath: validPaths[0]).deletingLastPathComponent().path]
        #endif
        do {
            try process.run()
        } catch {
            app.logConsole("Could not reveal selected assets",
                           severity: .error,
                           detail: error.localizedDescription)
        }
    }
}

private enum AssetViewMode: String, Sendable, AppStorageConvertible {
    case grid, list
}

enum AssetSortMode: String, Sendable, CaseIterable, AppStorageConvertible {
    case nameAscending
    case nameDescending
    case type
}

enum AssetCategoryFilter: String, Sendable, CaseIterable, AppStorageConvertible {
    case all
    case meshes
    case textures
}

enum AssetBrowserOrdering {
    static func filter(_ assets: [EditorAsset], category: AssetCategoryFilter) -> [EditorAsset] {
        switch category {
        case .all:
            return assets
        case .meshes:
            return assets.filter { $0.kind.isMesh }
        case .textures:
            return assets.filter { $0.kind.isTexture }
        }
    }

    static func sort(_ assets: [EditorAsset], mode: AssetSortMode) -> [EditorAsset] {
        assets.sorted { lhs, rhs in
            switch mode {
            case .nameAscending:
                return compare(lhs.name, rhs.name,
                               fallbackLHS: lhs.relativePath,
                               fallbackRHS: rhs.relativePath) == .orderedAscending
            case .nameDescending:
                return compare(lhs.name, rhs.name,
                               fallbackLHS: lhs.relativePath,
                               fallbackRHS: rhs.relativePath) == .orderedDescending
            case .type:
                let kindOrder = lhs.kind.rawValue.localizedCaseInsensitiveCompare(rhs.kind.rawValue)
                if kindOrder != .orderedSame { return kindOrder == .orderedAscending }
                return compare(lhs.name, rhs.name,
                               fallbackLHS: lhs.relativePath,
                               fallbackRHS: rhs.relativePath) == .orderedAscending
            }
        }
    }

    private static func compare(_ lhs: String,
                                _ rhs: String,
                                fallbackLHS: String,
                                fallbackRHS: String) -> ComparisonResult {
        let primary = lhs.localizedCaseInsensitiveCompare(rhs)
        guard primary == .orderedSame else { return primary }
        let fallback = fallbackLHS.localizedCaseInsensitiveCompare(fallbackRHS)
        guard fallback == .orderedSame else { return fallback }
        // Locale-aware comparison intentionally treats case-only differences
        // as equal. Keep the final order stable across reloads/platforms.
        if fallbackLHS != fallbackRHS { return fallbackLHS < fallbackRHS ? .orderedAscending : .orderedDescending }
        if lhs != rhs { return lhs < rhs ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }
}

// MARK: - Folder listing derivation

struct AssetFolderRef: Equatable {
    let name: String   // immediate folder name
    let path: String   // full relative path to navigate into
}

/// The immediate contents of one folder: subfolder names plus the assets that
/// live directly in it. Derived purely from the flat `relativePath` list.
struct AssetFolderListing {
    let folders: [AssetFolderRef]
    let assets: [EditorAsset]

    init(folders: [AssetFolderRef], assets: [EditorAsset]) {
        self.folders = folders
        self.assets = assets
    }

    static func make(folder: String, from all: [EditorAsset]) -> AssetFolderListing {
        let prefix = folder.isEmpty ? "" : folder + "/"
        var folderNames: Set<String> = []
        var assets: [EditorAsset] = []
        for asset in all {
            let rel = asset.relativePath
            guard rel.hasPrefix(prefix) else { continue }
            let remainder = rel.dropFirst(prefix.count)
            if let slash = remainder.firstIndex(of: "/") {
                folderNames.insert(String(remainder[..<slash]))
            } else if !remainder.isEmpty {
                assets.append(asset)
            }
        }
        let folders = folderNames.sorted {
            let comparison = $0.localizedCaseInsensitiveCompare($1)
            return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
        }
            .map { AssetFolderRef(name: $0, path: prefix + $0) }
        let sortedAssets = assets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return AssetFolderListing(folders: folders, assets: sortedAssets)
    }

    func sorted(by mode: AssetSortMode) -> AssetFolderListing {
        AssetFolderListing(folders: folders,
                           assets: AssetBrowserOrdering.sort(assets, mode: mode))
    }
}

// MARK: - Toolbar

private struct AssetBrowserToolbar: View {
    let searchText: Binding<String>
    let totalCount: Int
    let visibleCount: Int
    let isFiltering: Bool
    let onImport: () -> Void
    let onReload: () -> Void

    var body: some View {
        EditorPanelToolbar {
            Button(L("Import…")) { onImport() }
                .buttonStyle(.secondary)

            Button(L("Reload")) { onReload() }
                .buttonStyle(.secondary)

            TextField(L("Search Assets"),
                      text: searchText,
                      size: .small,
                      clearable: true)
                .font(.caption)
                .flex()

            EditorPanelBadge(isFiltering ? "\(visibleCount) / \(totalCount)" : "\(visibleCount)")
        }
    }
}

// MARK: - Breadcrumb + view toggle

private struct AssetBreadcrumbBar: View {
    let rootName: String
    let currentFolder: String
    let isSearching: Bool
    let viewMode: Binding<AssetViewMode>
    let sortMode: Binding<AssetSortMode>
    let categoryFilter: Binding<AssetCategoryFilter>
    let onNavigate: (String) -> Void

    private var segments: [(label: String, path: String)] {
        var result: [(String, String)] = [(rootName, "")]
        guard !currentFolder.isEmpty else { return result }
        var accumulated = ""
        for component in currentFolder.split(separator: "/") {
            accumulated = accumulated.isEmpty ? String(component) : accumulated + "/" + component
            result.append((String(component), accumulated))
        }
        return result
    }

    var body: some View {
        Row(alignment: .center, spacing: 4) {
            Icon(.svg(named: "folder",
                      in: EditorAppResourceBundle.bundle,
                      subdirectory: "ToolbarIcons"),
                 size: 13,
                 color: .onSurfaceVariant)
                .frame(width: 15, height: 15)

            if isSearching {
                Text(L("Search results"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceVariant)
            } else {
                for (index, crumb) in segments.enumerated() {
                    AssetBreadcrumbSegment(label: crumb.label,
                                           showSeparator: index > 0,
                                           isLast: index == segments.count - 1,
                                           action: { onNavigate(crumb.path) })
                }
            }

            Spacer(minLength: 0)

            AssetCategoryFilterButton(title: L("All"),
                                      isActive: categoryFilter.wrappedValue == .all,
                                      action: { categoryFilter.wrappedValue = .all })
            AssetCategoryFilterButton(title: L("Meshes"),
                                      isActive: categoryFilter.wrappedValue == .meshes,
                                      action: { categoryFilter.wrappedValue = .meshes })
            AssetCategoryFilterButton(title: L("Textures"),
                                      isActive: categoryFilter.wrappedValue == .textures,
                                      action: { categoryFilter.wrappedValue = .textures })

            AssetSortSelector(sortMode: sortMode)

            AssetViewModeButton(title: L("Grid"),
                                isActive: viewMode.wrappedValue == .grid,
                                action: { viewMode.wrappedValue = .grid })
            AssetViewModeButton(title: L("List"),
                                isActive: viewMode.wrappedValue == .list,
                                action: { viewMode.wrappedValue = .list })
        }
    }
}

private struct AssetCategoryFilterButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(isSelected: isActive, action: action) {
            Text(title, lineLimit: 1)
        }
        .buttonStyle(ToggleButtonStyle(height: 22))
    }
}

private struct AssetSortSelector: View {
    let sortMode: Binding<AssetSortMode>
    @State private var isPresented: Bool = false

    var body: some View {
        Popover(isPresented: $isPresented, width: 150) {
            Row(alignment: .center, spacing: 5) {
                Text(label(for: sortMode.wrappedValue), lineLimit: 1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceVariant)
                Icon(UICommonIcons.chevronDown, size: 8, color: .onSurfaceMuted)
            }
            .padding(horizontal: 7, vertical: 4)
            .background(.surfaceSunken)
            .cornerRadius(4)
        } content: {
            Menu(AssetSortMode.allCases.map { mode in
                .item(MenuItem(id: "asset-sort-\(mode.rawValue)",
                               title: label(for: mode),
                               isSelected: sortMode.wrappedValue == mode,
                               action: { sortMode.wrappedValue = mode }))
            }, width: 150, maxVisibleRows: 4, onItemActivated: {
                isPresented = false
            })
        }
    }

    private func label(for mode: AssetSortMode) -> String {
        switch mode {
        case .nameAscending: return L("Name A–Z")
        case .nameDescending: return L("Name Z–A")
        case .type: return L("Type")
        }
    }
}

private struct AssetBreadcrumbSegment: View {
    let label: String
    let showSeparator: Bool
    let isLast: Bool
    let action: () -> Void

    var body: some View {
        Row(alignment: .center, spacing: 4) {
            if showSeparator {
                Icon(UICommonIcons.chevronRight, size: 8, color: .onSurfaceMuted)
            }
            Button(action: action) {
                Text(label, lineLimit: 1)
                    .font(.caption)
                    .foregroundColor(isLast ? .onSurface : .onSurfaceVariant)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct AssetViewModeButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(isSelected: isActive, action: action) {
            Text(title, lineLimit: 1)
        }
        .buttonStyle(ToggleButtonStyle(height: 22))
    }
}

private struct AssetSelectionBar: View {
    let assets: [EditorAsset]
    let isAddEnabled: Bool
    let onAddToScene: () -> Void
    let onReveal: () -> Void

    private var containsOnlyMeshes: Bool {
        !assets.isEmpty && assets.allSatisfy { $0.kind.isMesh }
    }

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            Column(alignment: .leading, spacing: 1) {
                Text(assets.count == 1
                    ? assets[0].name
                    : String(format: L("%lld assets selected"), Int64(assets.count)),
                     lineLimit: 1)
                    .font(.caption)
                    .foregroundColor(.onSurface)
                Text(assets.count == 1
                    ? assets[0].relativePath
                    : String(format: L("%lld meshes selected"), Int64(assets.filter { $0.kind.isMesh }.count)),
                     lineLimit: 1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .flex(1, shrink: 1)

            if assets.count == 1 {
                Text(assets[0].kind.sceneKindLabel)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            if containsOnlyMeshes {
                Button(assets.count == 1
                    ? L("Add to Scene")
                    : String(format: L("Add %lld to Scene"), Int64(assets.count)),
                       isEnabled: isAddEnabled,
                       tooltip: isAddEnabled ? nil : L("Stop simulation to edit the scene"),
                       action: onAddToScene)
                    .buttonStyle(.primary)
            }
            Button(L("Reveal in Finder"), action: onReveal)
                .buttonStyle(.secondary)
        }
        .padding(horizontal: 10, vertical: 7)
        .background(.surfaceVariant)
    }
}

// MARK: - Folder tile / row

private struct AssetFolderTile: View {
    let name: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Box(direction: .column, alignItems: .center, spacing: 6) {
                Box(direction: .column, alignItems: .center, justifyContent: .center) {
                    Icon(.svg(named: "folder",
                              in: EditorAppResourceBundle.bundle,
                              subdirectory: "ToolbarIcons"),
                         size: 38,
                         color: .accent)
                        .frame(width: 38, height: 38)
                }
                .frame(width: 76, height: 72)
                .background(.surfaceVariant)
                .cornerRadius(5)

                Text(name, alignment: .center, lineLimit: 2)
                    .font(.caption)
                    .foregroundColor(.onSurface)
                    .frame(width: 76, height: 30)
                    .clipped()
            }
            .padding(horizontal: 5, vertical: 6)
            .frame(width: 88)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

private struct AssetFolderListRow: View {
    let name: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Row(alignment: .center, spacing: 9) {
                Box(direction: .column, alignItems: .center, justifyContent: .center) {
                    Icon(.svg(named: "folder",
                              in: EditorAppResourceBundle.bundle,
                              subdirectory: "ToolbarIcons"),
                         size: 18,
                         color: .accent)
                        .frame(width: 18, height: 18)
                }
                .frame(width: 26, height: 26)

                Text(name, lineLimit: 1)
                    .font(.body)
                    .foregroundColor(.onSurface)
                    .flex(1, shrink: 1, basis: 0)
                    .clipped()

                Spacer(minLength: 0)
            }
            .padding(horizontal: 8, vertical: 6)
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Asset grid tile

private struct AssetTile: View {
    let asset: EditorAsset
    let app: EditorApplication
    let isSelected: Bool
    let onSelect: (KeyModifiers) -> Void
    let onNavigate: (Int, KeyModifiers) -> Void
    let onSelectAll: () -> Void
    let onClearSelection: () -> Void
    let onActivate: () -> Void

    var body: some View {
        AssetDragSource(asset: asset,
                        app: app,
                        onSelect: onSelect,
                        onNavigate: onNavigate,
                        onSelectAll: onSelectAll,
                        onClearSelection: onClearSelection,
                        onActivate: onActivate) {
            Box(direction: .column, alignItems: .center, spacing: 6) {
                AssetThumbnail(asset: asset)

                Text(asset.name, alignment: .center, lineLimit: 2)
                    .font(.caption)
                    .foregroundColor(isSelected ? .onSurface : .onSurfaceVariant)
                    .frame(width: 76, height: 30)
                    .clipped()
            }
            .padding(horizontal: 5, vertical: 6)
            .frame(width: 88)
            .background(isSelected ? AssetTilePalette.selectionFill : AssetTilePalette.transparent)
            .cornerRadius(6)
            .border(isSelected ? AssetTilePalette.selectionStroke : AssetTilePalette.transparent, width: 1)
        }
    }
}

private struct AssetThumbnail: View {
    let asset: EditorAsset

    var body: some View {
        Box(direction: .column, alignItems: .stretch) {
            if asset.kind.isMesh {
                // Software-rendered shaded preview of the actual mesh, square-fit.
                MeshThumbnailView(assetID: asset.id, meshIndex: asset.meshIndex)
                    .absolutePosition(left: 0, top: 0, right: 0, bottom: 0)
            } else if asset.kind.isTexture {
                TextureThumbnailView(path: asset.absolutePath, width: 76, height: 72)
                    .absolutePosition(left: 0, top: 0, right: 0, bottom: 0)
            } else {
                Box(direction: .column, alignItems: .center, justifyContent: .center) {
                    Icon(.svg(named: asset.kind.iconName,
                              in: EditorAppResourceBundle.bundle,
                              subdirectory: "HierarchyIcons"),
                         size: 24,
                         color: asset.kind.tint)
                }
                .absolutePosition(left: 0, top: 0, right: 0, bottom: 0)
            }

            // Format badge — a small corner chip over the preview.
            Box(direction: .column, alignItems: .flexStart) {
                Text(asset.kind.badge)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(horizontal: 4, vertical: 1)
                    .background(asset.kind.tint)
                    .cornerRadius(3)
            }
            .absolutePosition(left: 4, bottom: 4)
        }
        .frame(width: 76, height: 72)
        .background(AssetTilePalette.thumbnailBackdrop)
        .cornerRadius(5)
    }
}

private struct TextureThumbnailView: View {
    let path: String
    let width: Float
    let height: Float

    var body: some View {
        Box(direction: .column, alignItems: .center, justifyContent: .center) {
            AsyncImageThumbnail(path: path, width: width, height: height) {
                Box(direction: .column, alignItems: .center, justifyContent: .center) {
                    Icon(.svg(named: "squares-2x2",
                              in: EditorAppResourceBundle.bundle,
                              subdirectory: "HierarchyIcons"),
                         size: Swift.min(Swift.min(width, height), 24),
                         color: .success)
                }
                .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height)
        .background(.surfaceSunken)
    }
}

// MARK: - Asset list row

private struct AssetListRow: View {
    let asset: EditorAsset
    let app: EditorApplication
    let isSelected: Bool
    let onSelect: (KeyModifiers) -> Void
    let onNavigate: (Int, KeyModifiers) -> Void
    let onSelectAll: () -> Void
    let onClearSelection: () -> Void
    let onActivate: () -> Void

    var body: some View {
        AssetDragSource(asset: asset,
                        app: app,
                        onSelect: onSelect,
                        onNavigate: onNavigate,
                        onSelectAll: onSelectAll,
                        onClearSelection: onClearSelection,
                        onActivate: onActivate) {
            Row(alignment: .center, spacing: 9) {
                Box(direction: .column, alignItems: .center, justifyContent: .center) {
                    if asset.kind.isTexture {
                        TextureThumbnailView(path: asset.absolutePath, width: 26, height: 26)
                            .cornerRadius(3)
                    } else {
                        Icon(.svg(named: asset.kind.iconName,
                                  in: EditorAppResourceBundle.bundle,
                                  subdirectory: "HierarchyIcons"),
                             size: 18,
                             color: asset.kind.tint)
                            .frame(width: 18, height: 18)
                    }
                }
                .frame(width: 26, height: 26)

                Box(direction: .column, alignItems: .stretch, spacing: 1) {
                    Text(asset.name, lineLimit: 1)
                        .font(.body)
                        .foregroundColor(.onSurface)

                    Text(asset.relativePath, lineLimit: 1)
                        .font(.caption)
                        .foregroundColor(.onSurfaceVariant)
                }
                .flex(1, shrink: 1, basis: 0)
                .clipped()

                Text(asset.kind.badge)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 8, vertical: 6)
            .background(isSelected ? AssetTilePalette.selectionFill : AssetTilePalette.transparent)
            .cornerRadius(3)
            .border(isSelected ? AssetTilePalette.selectionStroke : AssetTilePalette.transparent, width: 1)
        }
    }
}

// MARK: - Empty / placeholder states

private struct AssetBrowserEmptyState: View {
    let projectDirectory: String
    let onImport: () -> Void

    var body: some View {
        Box(direction: .column, alignItems: .center, justifyContent: .center, spacing: 10) {
            Text(L("No assets yet"))
                .font(.bodyStrong)
                .foregroundColor(.onSurface)

            Text(L("Import .glb, .gltf, .obj, or texture files — or drop them anywhere inside the project folder and reload."))
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)
                .frame(width: 260)

            Text(projectDirectory)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)

            Button(L("Import…")) { onImport() }
                .buttonStyle(.primary)
        }
        .padding(horizontal: 16, vertical: 16)
    }
}

private struct AssetBrowserPlaceholder: View {
    let title: String
    let subtitle: String

    var body: some View {
        Box(direction: .column, alignItems: .center, justifyContent: .center, spacing: 6) {
            Text(title)
                .font(.bodyStrong)
                .foregroundColor(.onSurface)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
        }
        .padding(horizontal: 16, vertical: 16)
    }
}

// MARK: - Styling helpers

/// Hardcoded selection accents (mirrors `HierarchyTreeRowStyle`'s approach):
/// a saturated blue reads clearly over both the light and dark surface grays.
private enum AssetTilePalette {
    static let transparent = Color(r: 0, g: 0, b: 0, a: 0)
    static let selectionFill = Color(red: 0x4F, green: 0x9D, blue: 0xFF, alpha: 0x33)
    static let selectionStroke = Color(red: 0x4F, green: 0x9D, blue: 0xFF, alpha: 0xC8)
    /// Fixed neutral slate backdrop for thumbnails so the clay-shaded mesh reads
    /// the same in light and dark themes (matches how UE/Unity render previews).
    static let thumbnailBackdrop = Color(red: 0x2E, green: 0x31, blue: 0x38)
}

private extension ImportableAssetKind {
    var badge: String {
        switch self {
        case .gltf: return "glTF"
        case .glb:  return "GLB"
        case .obj:  return "OBJ"
        case .png, .jpg, .jpeg, .webp, .tga, .bmp, .gif, .svg:
            return "TEX"
        }
    }

    var tint: SemanticColorRef {
        switch self {
        case .gltf, .glb: return .accent
        case .obj:        return .warning
        case .png, .jpg, .jpeg, .webp, .tga, .bmp, .gif, .svg:
            return .success
        }
    }

    var iconName: String {
        isTexture ? "squares-2x2" : "cube"
    }
}

// MARK: - Drag Source Primitive

/// 资产 tile 的指针交互层。按下选中并记录起点；指针移动超过阈值才真正
/// 开始拖动(避免单击被误判为拖放、刷屏 console);拖动中 acquire pointer
/// capture，抬起时若已在拖动则根据光标是否落在视口决定生成实体。
private struct AssetDragSource<Content: View>: _PrimitiveView {
    let asset: EditorAsset
    let app: EditorApplication
    let onSelect: (KeyModifiers) -> Void
    let onNavigate: (Int, KeyModifiers) -> Void
    let onSelectAll: () -> Void
    let onClearSelection: () -> Void
    let onActivate: () -> Void
    let content: Content

    init(asset: EditorAsset,
         app: EditorApplication,
         onSelect: @escaping (KeyModifiers) -> Void,
         onNavigate: @escaping (Int, KeyModifiers) -> Void,
         onSelectAll: @escaping () -> Void,
         onClearSelection: @escaping () -> Void,
         onActivate: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.asset = asset
        self.app = app
        self.onSelect = onSelect
        self.onNavigate = onNavigate
        self.onSelectAll = onSelectAll
        self.onClearSelection = onClearSelection
        self.onActivate = onActivate
        self.content = content()
    }

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.isFocusable = true
        n.cursor = .pointer
        return n
    }

    func _updateNode(_ node: Node) {
        guard let registry = InteractionRegistryHolder.current else { return }
        let asset = self.asset
        let app = self.app
        let onSelect = self.onSelect
        let onNavigate = self.onNavigate
        let onSelectAll = self.onSelectAll
        let onClearSelection = self.onClearSelection
        let onActivate = self.onActivate
        let capture = PointerCaptureHolder.current
        let isDragEnabled = asset.kind.isMesh
            && app.store.state.timing.playbackState == .stopped
        AssetBrowserFocusRegistry.register(assetID: asset.id, node: node)

        registry.setPointer(node, route: InputHandlerRoute(role: .drag,
                                                           priority: .capture,
                                                           debugName: "asset.drag")) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                onSelect(event.modifiers)
                guard isDragEnabled else { return .handled }
                AssetDragGesture.pending = AssetDragGesture.Pending(assetID: asset.id,
                                                                    startX: event.x,
                                                                    startY: event.y,
                                                                    dragging: false)
                capture?.acquire(node)
                return .handled
            case .up:
                // Only resolve a drop if a drag actually began; a plain click
                // just selects (handled on .down) without spawning anything.
                if app.store.state.navigation.activeAssetDrag != nil {
                    _ = app.handleAssetDrop(at: event.x, cursorY: event.y)
                }
                AssetDragGesture.pending = nil
                capture?.release()
                return .handled
            }
        }

        registry.setMotion(node, route: InputHandlerRoute(role: .drag,
                                                          priority: .capture,
                                                          debugName: "asset.drag")) { event, _ in
            guard var pending = AssetDragGesture.pending, pending.assetID == asset.id else {
                return .ignored
            }
            if pending.dragging {
                app.store.dispatch(.updateAssetDragCursor(x: event.x, y: event.y))
            } else {
                let dx = event.x - pending.startX
                let dy = event.y - pending.startY
                if dx * dx + dy * dy >= AssetDragGesture.thresholdSquared {
                    pending.dragging = true
                    AssetDragGesture.pending = pending
                    app.store.dispatch(.beginAssetDrag(asset.dragPayload()))
                    app.store.dispatch(.updateAssetDragCursor(x: event.x, y: event.y))
                }
            }
            return .handled
        }

        registry.setKey(node, route: InputHandlerRoute(role: .drag,
                                                       priority: .capture,
                                                       debugName: "asset.drag")) { event, _ in
            // Esc cancels an in-progress drag without spawning.
            if app.store.state.navigation.activeAssetDrag != nil,
               event.scancode == ComposeScancode.escape {
                app.store.dispatch(.endAssetDrag)
                AssetDragGesture.pending = nil
                PointerCaptureHolder.current?.release()
                return .handled
            }
            switch event.scancode {
            case ComposeScancode.arrowLeft, ComposeScancode.arrowUp:
                onNavigate(-1, event.modifiers)
                return .handled
            case ComposeScancode.arrowRight, ComposeScancode.arrowDown:
                onNavigate(1, event.modifiers)
                return .handled
            case ComposeScancode.a where event.modifiers.hasGui || event.modifiers.hasCtrl:
                onSelectAll()
                return .handled
            case ComposeScancode.return, ComposeScancode.keypadEnter:
                guard !event.isRepeat else { return .handled }
                onActivate()
                return .handled
            case ComposeScancode.escape:
                onClearSelection()
                return .handled
            default:
                return .ignored
            }
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let l = LayoutNode()
        l.flexDirection = .column
        l.alignItems = .stretch
        return l
    }

    var _children: [any View] { [content] }
}

/// Transient gesture state for an in-flight asset drag. Only one pointer
/// gesture is ever active (pointer capture guarantees it), so a single global
/// slot is safe and — unlike closure-captured state — it survives the
/// recomposes that selection/drag dispatches trigger mid-gesture. Mirrors the
/// existing `EditorViewportDropTarget` transient-global pattern.
private enum AssetDragGesture {
    struct Pending {
        let assetID: String
        let startX: Float
        let startY: Float
        var dragging: Bool
    }

    /// Movement (in logical px) past which a press becomes a drag.
    static let dragThreshold: Float = 4
    static var thresholdSquared: Float { dragThreshold * dragThreshold }

    nonisolated(unsafe) static var pending: Pending?
}

private final class AssetBrowserWeakFocusNode {
    weak var node: Node?
    init(_ node: Node) { self.node = node }
}

private enum AssetBrowserFocusRegistry {
    nonisolated(unsafe) private static var nodes: [String: AssetBrowserWeakFocusNode] = [:]

    static func register(assetID: String, node: Node) {
        nodes[assetID] = AssetBrowserWeakFocusNode(node)
        if nodes.count > 512 && nodes.count.isMultiple(of: 128) {
            nodes = nodes.filter { $0.value.node != nil }
        }
    }

    static func focus(_ assetID: String) {
        guard let node = nodes[assetID]?.node else { return }
        scrollIntoView(node)
        FocusChainHolder.current?.focus(node)
    }

    private static func scrollIntoView(_ node: Node) {
        guard var scrollView = node.parent else { return }
        while !scrollView.clipsToBounds {
            guard let parent = scrollView.parent else { return }
            scrollView = parent
        }

        let viewport = scrollView.absoluteFrame
        let item = node.absoluteFrame
        var offset = scrollView.contentOffset
        if item.minY < viewport.minY {
            offset.y = max(0, offset.y - (viewport.minY - item.minY))
        } else if item.maxY > viewport.maxY {
            offset.y += item.maxY - viewport.maxY
        }
        if item.minX < viewport.minX {
            offset.x = max(0, offset.x - (viewport.minX - item.minX))
        } else if item.maxX > viewport.maxX {
            offset.x += item.maxX - viewport.maxX
        }
        if offset != scrollView.contentOffset {
            scrollView.contentOffset = offset
        }
    }
}

private enum AssetListingRow {
    case folder(AssetFolderRef)
    case asset(EditorAsset)
    var id: String { switch self { case .folder(let folder): return "folder/" + folder.path; case .asset(let asset): return "asset/" + asset.id } }
}
