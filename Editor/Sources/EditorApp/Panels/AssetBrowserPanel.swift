import Foundation
import EditorCore
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import EngineKernel
import AssetPipeline

/// Content Browser — the editor's asset panel, modeled after Unreal's. A
/// toolbar (import + live search + item count), a path bar with a grid/list
/// toggle, and a scrollable, reflowing tile grid. Every tile is a drag source:
/// click to select, drag past a threshold to drop a Static Mesh into the
/// viewport. Import works on every platform through the native file dialog.
struct AssetBrowserPanel: View {
    let app: EditorApplication

    @State private var searchText: String = ""
    @State private var viewMode: AssetViewMode = .grid
    @State private var selectedAssetID: String? = nil

    private func importAssets() {
        guard let display = AppDisplayHandleHolder.current else { return }
        // The picker is invoked from a button tap on the main loop thread.
        MainActor.assumeIsolated {
            display.requestOpenFile(
                filters: [(name: L("3D Models"), extensions: ["glb", "gltf", "obj"])],
                allowsMultiple: true,
                defaultPath: app.projectDirectory
            ) { paths in
                // Delivered on the main thread by the platform host.
                importFiles(paths)
            }
        }
    }

    /// Copies the chosen files into the project directory (unless they already
    /// live there) and reloads the asset registry.
    private func importFiles(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let dest = URL(fileURLWithPath: app.projectDirectory, isDirectory: true)
            .resolvingSymlinksInPath()
        var copied = false
        for path in paths {
            let src = URL(fileURLWithPath: path)
            let target = dest.appendingPathComponent(src.lastPathComponent)
            // Already inside the project? No copy needed — just register it.
            if src.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path {
                copied = true
                continue
            }
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: src, to: target)
                copied = true
            } catch {
                // Skip files that can't be copied; the reload simply won't list them.
            }
        }
        if copied { _ = app.reloadAssets() }
    }

    private func filtered(_ assets: [EditorAsset]) -> [EditorAsset] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return assets }
        return assets.filter {
            $0.name.range(of: query, options: .caseInsensitive) != nil
                || $0.relativePath.range(of: query, options: .caseInsensitive) != nil
        }
    }

    var body: some View {
        StoreScope(app.store) { _ in
            let allAssets = EditorAssetCatalog.entries()
            let visible = filtered(allAssets)

            Box(direction: .column, alignItems: .stretch) {
                AssetBrowserToolbar(searchText: $searchText,
                                    totalCount: allAssets.count,
                                    visibleCount: visible.count,
                                    isFiltering: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                    onImport: { importAssets() })
                    .padding(horizontal: 10, vertical: 7)

                Divider()

                AssetBrowserPathBar(projectDirectory: app.projectDirectory,
                                    viewMode: $viewMode)
                    .padding(horizontal: 10, vertical: 5)

                Divider()

                if allAssets.isEmpty {
                    AssetBrowserEmptyState(projectDirectory: app.projectDirectory,
                                           onImport: { importAssets() })
                        .flex()
                } else if visible.isEmpty {
                    AssetBrowserNoResults(query: searchText)
                        .flex()
                } else {
                    ScrollView(.vertical) {
                        switch viewMode {
                        case .grid:
                            Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 10) {
                                for asset in visible {
                                    AssetTile(asset: asset,
                                              app: app,
                                              isSelected: selectedAssetID == asset.id,
                                              onSelect: { selectedAssetID = asset.id })
                                }
                            }
                            .padding(horizontal: 10, vertical: 10)
                        case .list:
                            Box(direction: .column, alignItems: .stretch, spacing: 2) {
                                for asset in visible {
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
            .frame(minWidth: 240)
        }
    }
}

private enum AssetViewMode: Sendable, Equatable {
    case grid, list
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

            Text(isFiltering ? "\(visibleCount)/\(totalCount)" : "\(totalCount) items")
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
    }
}

// MARK: - Path bar + view toggle

private struct AssetBrowserPathBar: View {
    let projectDirectory: String
    let viewMode: Binding<AssetViewMode>

    private var rootName: String {
        let name = URL(fileURLWithPath: projectDirectory, isDirectory: true).lastPathComponent
        return name.isEmpty ? L("Content") : name
    }

    var body: some View {
        Row(alignment: .center, spacing: 6) {
            Image(resource: .svg(named: "squares-2x2", in: .module, subdirectory: "HierarchyIcons"),
                  width: 13, height: 13,
                  tint: .white,
                  contentMode: .fit,
                  renderingMode: .alphaMask)
                .foregroundColor(.onSurfaceVariant)
                .frame(width: 14, height: 14)

            Text(rootName)
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)

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

private struct AssetViewModeButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .foregroundColor(isActive ? .accent : .onSurfaceMuted)
                .padding(horizontal: 7, vertical: 3)
                .background(isActive ? AssetTilePalette.selectionFill : AssetTilePalette.transparent)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Grid tile

private struct AssetTile: View {
    let asset: EditorAsset
    let app: EditorApplication
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        AssetDragSource(asset: asset, app: app, onSelect: onSelect) {
            Box(direction: .column, alignItems: .center, spacing: 6) {
                AssetThumbnail(kind: asset.kind)

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
    let kind: ImportableAssetKind

    var body: some View {
        Box(direction: .column, alignItems: .center, justifyContent: .center, spacing: 6) {
            Image(resource: .svg(named: "cube", in: .module, subdirectory: "HierarchyIcons"),
                  width: 30, height: 30,
                  tint: .white,
                  contentMode: .fit,
                  renderingMode: .alphaMask)
                .foregroundColor(kind.tint)
                .frame(width: 30, height: 30)

            Text(kind.badge)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
        .frame(width: 76, height: 72)
        .background(.surfaceVariant)
        .cornerRadius(5)
    }
}

// MARK: - List row

private struct AssetListRow: View {
    let asset: EditorAsset
    let app: EditorApplication
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        AssetDragSource(asset: asset, app: app, onSelect: onSelect) {
            Row(alignment: .center, spacing: 9) {
                Box(direction: .column, alignItems: .center, justifyContent: .center) {
                    Image(resource: .svg(named: "cube", in: .module, subdirectory: "HierarchyIcons"),
                          width: 18, height: 18,
                          tint: .white,
                          contentMode: .fit,
                          renderingMode: .alphaMask)
                        .foregroundColor(asset.kind.tint)
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

// MARK: - Empty / no-results states

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

private struct AssetBrowserNoResults: View {
    let query: String

    var body: some View {
        Box(direction: .column, alignItems: .center, justifyContent: .center, spacing: 6) {
            Text(L("No matching assets"))
                .font(.bodyStrong)
                .foregroundColor(.onSurface)
            Text("\"\(query)\"")
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
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
}

private extension ImportableAssetKind {
    var badge: String {
        switch self {
        case .gltf: return "glTF"
        case .glb:  return "GLB"
        case .obj:  return "OBJ"
        }
    }

    var tint: SemanticColorRef {
        switch self {
        case .gltf, .glb: return .accent
        case .obj:        return .warning
        }
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
