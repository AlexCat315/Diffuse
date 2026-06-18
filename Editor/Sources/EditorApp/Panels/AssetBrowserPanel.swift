import Foundation
import EditorCore
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import EngineKernel
import AssetPipeline

/// Content Browser — the editor's asset panel, modeled after Unreal's. A
/// toolbar (import + live search + item count), a breadcrumb bar with a
/// grid/list toggle, and a scrollable, reflowing grid that navigates the
/// project's folder hierarchy (folders first, then assets). Every asset tile is
/// a drag source: click to select, drag past a threshold to drop a Static Mesh
/// into the viewport. Import works on every platform via the native file
/// dialog, into the folder currently being viewed.
struct AssetBrowserPanel: View {
    let app: EditorApplication

    @State private var searchText: String = ""
    @AppStorage("assetBrowser.viewMode") private var viewMode: AssetViewMode = .grid
    @State private var selectedAssetID: String? = nil
    /// Relative folder path currently shown ("" == project root). Uses "/" as
    /// separator, matching `AssetRegistryEntry.relativePath`.
    @State private var currentFolder: String = ""

    private func importAssets() {
        guard let display = AppDisplayHandleHolder.current else { return }
        let folder = currentFolder
        // The picker is invoked from a button tap on the main loop thread.
        MainActor.assumeIsolated {
            display.requestOpenFile(
                filters: [(name: L("3D Models"),
                           extensions: AssetImportResolver.supportedModelExtensions.sorted()),
                          (name: L("Textures"),
                           extensions: AssetImportResolver.supportedTextureExtensions.sorted())],
                allowsMultiple: true,
                defaultPath: importDestination(for: folder)
            ) { paths in
                // Delivered on the main thread by the platform host.
                importFiles(paths, into: folder)
            }
        }
    }

    private func importDestination(for folder: String) -> String {
        let base = URL(fileURLWithPath: app.projectDirectory, isDirectory: true)
        return folder.isEmpty ? base.path : base.appendingPathComponent(folder, isDirectory: true).path
    }

    /// Imports the chosen files into the viewed folder. Each file is dispatched
    /// through `AssetImportResolver`, which (like UE/Godot) pulls every external
    /// dependency — glTF `.bin` buffers and textures, OBJ `.mtl` + its maps —
    /// along with the asset, preserving relative layout. Results are reported in
    /// the console: imported count, missing dependencies, unsupported formats.
    private func importFiles(_ paths: [String], into folder: String) {
        guard !paths.isEmpty else { return }
        let destDir = URL(fileURLWithPath: importDestination(for: folder), isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        var importedNames: [String] = []
        var missingDependencies: [String] = []
        var unsupported: [String] = []

        for path in paths {
            let src = URL(fileURLWithPath: path)
            guard AssetImportResolver.isSupported(src) else {
                unsupported.append(src.lastPathComponent)
                continue
            }
            let outcome = copyAsset(from: src, into: destDir)
            if outcome.copied { importedNames.append(src.lastPathComponent) }
            missingDependencies.append(contentsOf: outcome.missing)
        }

        if !importedNames.isEmpty {
            _ = app.reloadAssets()
            // A re-imported file may reuse an id, so drop cached thumbnails.
            AssetThumbnailRasterizer.invalidate()
            app.logConsole("Imported \(importedNames.count) asset\(importedNames.count == 1 ? "" : "s")",
                           detail: importedNames.joined(separator: ", "))
        }
        if !missingDependencies.isEmpty {
            app.logConsole("Asset imported with missing dependencies",
                           severity: .warning,
                           detail: missingDependencies.joined(separator: ", "))
        }
        if !unsupported.isEmpty {
            app.logConsole("Unsupported format — import models or textures",
                           severity: .warning,
                           detail: unsupported.joined(separator: ", "))
        }
    }

    /// Copies a resolved asset (and its dependencies) into `destDir`, preserving
    /// each file's relative path. Returns whether anything was copied and the
    /// relative paths of any referenced files missing from disk.
    private func copyAsset(from src: URL, into destDir: URL) -> (copied: Bool, missing: [String]) {
        var copiedAny = false
        var missing: [String] = []
        for file in AssetImportResolver.resolve(src) {
            let target = destDir.appendingPathComponent(file.relativePath)
            // Already in place (importing from inside the project)? Count it.
            if file.source.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path {
                copiedAny = true
                continue
            }
            guard FileManager.default.fileExists(atPath: file.source.path) else {
                missing.append(file.relativePath)
                continue
            }
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: file.source, to: target)
                copiedAny = true
            } catch {
                missing.append(file.relativePath)
            }
        }
        return (copiedAny, missing)
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
        selectedAssetID = nil
    }

    var body: some View {
        StoreScope(app.store) { _ in
            let allAssets = EditorAssetCatalog.entries()
            let isSearching = !trimmedQuery.isEmpty
            // While searching, ignore folder structure and show flat matches
            // across the whole project (Unreal's search behaviour).
            let listing = isSearching
                ? AssetFolderListing(folders: [], assets: searchMatches(allAssets))
                : AssetFolderListing.make(folder: currentFolder, from: allAssets)
            let itemCount = listing.folders.count + listing.assets.count

            Box(direction: .column, alignItems: .stretch) {
                AssetBrowserToolbar(searchText: $searchText,
                                    totalCount: allAssets.count,
                                    visibleCount: itemCount,
                                    isFiltering: isSearching,
                                    onImport: { importAssets() })
                    .padding(horizontal: 10, vertical: 7)

                Divider()

                AssetBreadcrumbBar(rootName: rootName,
                                   currentFolder: currentFolder,
                                   isSearching: isSearching,
                                   viewMode: $viewMode,
                                   onNavigate: { navigate(to: $0) })
                    .padding(horizontal: 10, vertical: 5)

                Divider()

                content(allAssets: allAssets, listing: listing, isSearching: isSearching)
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
                         isSearching: Bool) -> some View {
        if allAssets.isEmpty {
            AssetBrowserEmptyState(projectDirectory: app.projectDirectory,
                                   onImport: { importAssets() })
                .flex()
        } else if listing.folders.isEmpty && listing.assets.isEmpty {
            if isSearching {
                AssetBrowserPlaceholder(title: L("No matching assets"),
                                        subtitle: "\"\(trimmedQuery)\"")
                    .flex()
            } else {
                AssetBrowserPlaceholder(title: L("This folder is empty"),
                                        subtitle: currentFolder)
                    .flex()
            }
        } else {
            ScrollView(.vertical, scrollbarGutter: .stable) {
                switch viewMode {
                case .grid:
                    Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 10) {
                        for folder in listing.folders {
                            AssetFolderTile(name: folder.name,
                                            onOpen: { navigate(to: folder.path) })
                        }
                        for asset in listing.assets {
                            AssetTile(asset: asset,
                                      app: app,
                                      isSelected: selectedAssetID == asset.id,
                                      onSelect: { selectedAssetID = asset.id })
                        }
                    }
                    .padding(horizontal: 10, vertical: 10)
                case .list:
                    Box(direction: .column, alignItems: .stretch, spacing: 2) {
                        for folder in listing.folders {
                            AssetFolderListRow(name: folder.name,
                                               onOpen: { navigate(to: folder.path) })
                        }
                        for asset in listing.assets {
                            AssetListRow(asset: asset,
                                         app: app,
                                         isSelected: selectedAssetID == asset.id,
                                         onSelect: { selectedAssetID = asset.id })
                        }
                    }
                    .padding(horizontal: 6, vertical: 6)
                }
            }
            .flex()
        }
    }
}

private enum AssetViewMode: String, Sendable, AppStorageConvertible {
    case grid, list
}

// MARK: - Folder listing derivation

private struct AssetFolderRef: Equatable {
    let name: String   // immediate folder name
    let path: String   // full relative path to navigate into
}

/// The immediate contents of one folder: subfolder names plus the assets that
/// live directly in it. Derived purely from the flat `relativePath` list.
private struct AssetFolderListing {
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
        let folders = folderNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { AssetFolderRef(name: $0, path: prefix + $0) }
        let sortedAssets = assets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return AssetFolderListing(folders: folders, assets: sortedAssets)
    }
}

// MARK: - Toolbar

private struct AssetBrowserToolbar: View {
    let searchText: Binding<String>
    let totalCount: Int
    let visibleCount: Int
    let isFiltering: Bool
    let onImport: () -> Void

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            Button(L("Import…")) { onImport() }
                .buttonStyle(.secondary)

            TextField(L("Search Assets"),
                      text: searchText,
                      size: .small,
                      clearable: true)
                .font(.caption)
                .flex()

            Text(isFiltering ? "\(visibleCount)/\(totalCount)" : "\(visibleCount) items")
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
    }
}

// MARK: - Breadcrumb + view toggle

private struct AssetBreadcrumbBar: View {
    let rootName: String
    let currentFolder: String
    let isSearching: Bool
    let viewMode: Binding<AssetViewMode>
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
            Icon(.svg(named: "folder", in: .module, subdirectory: "ToolbarIcons"), size: 13, color: .onSurfaceVariant)
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

            AssetViewModeButton(title: L("Grid"),
                                isActive: viewMode.wrappedValue == .grid,
                                action: { viewMode.wrappedValue = .grid })
            AssetViewModeButton(title: L("List"),
                                isActive: viewMode.wrappedValue == .list,
                                action: { viewMode.wrappedValue = .list })
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

// MARK: - Folder tile / row

private struct AssetFolderTile: View {
    let name: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Box(direction: .column, alignItems: .center, spacing: 6) {
                Box(direction: .column, alignItems: .center, justifyContent: .center) {
                    Icon(.svg(named: "folder", in: .module, subdirectory: "ToolbarIcons"), size: 38, color: .accent)
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
                    Icon(.svg(named: "folder", in: .module, subdirectory: "ToolbarIcons"), size: 18, color: .accent)
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
    let onSelect: () -> Void

    var body: some View {
        AssetDragSource(asset: asset, app: app, onSelect: onSelect) {
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
            } else {
                Box(direction: .column, alignItems: .center, justifyContent: .center) {
                    Icon(.svg(named: asset.kind.iconName, in: .module, subdirectory: "HierarchyIcons"),
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

// MARK: - Asset list row

private struct AssetListRow: View {
    let asset: EditorAsset
    let app: EditorApplication
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        AssetDragSource(asset: asset, app: app, onSelect: onSelect) {
            Row(alignment: .center, spacing: 9) {
                Box(direction: .column, alignItems: .center, justifyContent: .center) {
                    Icon(.svg(named: asset.kind.iconName, in: .module, subdirectory: "HierarchyIcons"),
                         size: 18,
                         color: asset.kind.tint)
                        .frame(width: 18, height: 18)
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

            Text(L("Import .glb, .gltf, or .obj files — or drop them anywhere inside the project folder and reload."))
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
    let onSelect: () -> Void
    let content: Content

    init(asset: EditorAsset,
         app: EditorApplication,
         onSelect: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.asset = asset
        self.app = app
        self.onSelect = onSelect
        self.content = content()
    }

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.cursor = .pointer
        return n
    }

    func _updateNode(_ node: Node) {
        guard let registry = InteractionRegistryHolder.current else { return }
        let asset = self.asset
        let app = self.app
        let onSelect = self.onSelect
        let capture = PointerCaptureHolder.current

        registry.setPointer(node, route: InputHandlerRoute(role: .drag,
                                                           priority: .capture,
                                                           debugName: "asset.drag")) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                onSelect()
                AssetDragGesture.pending = AssetDragGesture.Pending(assetID: asset.id,
                                                                    startX: event.x,
                                                                    startY: event.y,
                                                                    dragging: false)
                capture?.acquire(node)
                return .handled
            case .up:
                // Only resolve a drop if a drag actually began; a plain click
                // just selects (handled on .down) without spawning anything.
                if app.store.state.activeAssetDrag != nil {
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
            if app.store.state.activeAssetDrag != nil,
               event.keycode == 0x1B /* SDLK_ESCAPE */ {
                app.store.dispatch(.endAssetDrag)
                AssetDragGesture.pending = nil
                PointerCaptureHolder.current?.release()
                return .handled
            }
            return .ignored
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
