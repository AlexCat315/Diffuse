import AppKit
import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import EngineKernel
import AssetPipeline

struct AssetBrowserPanel: View {
    let app: EditorApplication

    private func importAssets() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = L("Import Assets")
        panel.message = L("Choose .glb, .gltf, or .obj files to import into this project.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = []
        panel.begin { response in
            guard response == .OK else { return }
            let dest = URL(fileURLWithPath: self.app.projectDirectory, isDirectory: true)
            var copied = false
            for src in panel.urls {
                let target = dest.appendingPathComponent(src.lastPathComponent)
                do {
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                    try FileManager.default.copyItem(at: src, to: target)
                    copied = true
                } catch {
                    // Skip files that can't be copied; registry will warn on import failure.
                }
            }
            if copied {
                Task { @MainActor in _ = self.app.reloadAssets() }
            }
        }
        #endif
    }

    var body: some View {
        StoreScope(app.store) { store in
            let assets = EditorAssetCatalog.entries()
            Box(direction: .column, alignItems: .stretch) {
                AssetBrowserHeader(
                    dragLabel: store.activeAssetDrag?.displayName,
                    onImport: { importAssets() }
                )
                .padding(horizontal: 10, vertical: 7)

                Divider()

                Box(direction: .column, alignItems: .stretch, spacing: 2) {
                    if assets.isEmpty {
                        AssetBrowserEmptyState(projectDirectory: app.projectDirectory)
                    } else {
                        for asset in assets {
                            AssetBrowserRow(asset: asset, app: app)
                        }
                    }
                }
                .padding(horizontal: 6, vertical: 6)
                .flex()
            }
            .frame(minWidth: 220)
        }
    }
}

private struct AssetBrowserHeader: View {
    let dragLabel: String?
    let onImport: () -> Void

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            Text(L("Assets"))
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)

            Spacer(minLength: 0)

            if let dragLabel {
                Text("Dragging: \(dragLabel)")
                    .font(.caption)
                    .foregroundColor(.warning)
            } else {
                Text("\(EditorAssetCatalog.entries().count) items")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                Button(L("Import…")) { onImport() }
                    .buttonStyle(.ghost)
            }
        }
    }
}

private struct AssetBrowserEmptyState: View {
    let projectDirectory: String

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 6) {
            Text(L("No importable assets"))
                .font(.bodyStrong)
                .foregroundColor(.onSurface)
            Text(projectDirectory)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
            Text(L("Use the Import… button above, or copy .glb, .gltf, or .obj files anywhere inside the project directory and reload."))
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)
        }
        .padding(horizontal: 8, vertical: 8)
    }
}

private struct AssetBrowserRow: View {
    let asset: EditorAsset
    let app: EditorApplication

    var body: some View {
        AssetDragSource(asset: asset, app: app) {
            Row(alignment: .center, spacing: 8) {
                AssetGlyph(kind: asset.kind)

                Box(direction: .column, alignItems: .stretch, spacing: 1) {
                    Text(asset.name)
                        .font(.body)
                        .foregroundColor(.onSurface)

                    Text(asset.relativePath)
                        .font(.caption)
                        .foregroundColor(.onSurfaceVariant)
                }

                Spacer(minLength: 0)
            }
            .padding(horizontal: 7, vertical: 5)
            .background(.surfaceVariant)
            .cornerRadius(2)
        }
    }
}

private struct AssetGlyph: View {
    let kind: ImportableAssetKind

    var body: some View {
        let label: String
        switch kind {
        case .gltf, .glb: label = "GL"
        case .obj: label = "OBJ"
        }

        return Text(label)
            .font(.bodyStrong)
            .foregroundColor(.onSurfaceMuted)
    }
}

// MARK: - Drag Source Primitive

/// 资产行的指针交互层。按下时记录拖动 payload 并 acquire pointer capture，
/// 这样后续 motion / up 都路由回这个节点；抬起时根据光标是否落在视口
/// 矩形里决定生成实体或取消。
private struct AssetDragSource<Content: View>: _PrimitiveView {
    let asset: EditorAsset
    let app: EditorApplication
    let content: Content

    init(asset: EditorAsset,
         app: EditorApplication,
         @ViewBuilder content: () -> Content) {
        self.asset = asset
        self.app = app
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
        let capture = PointerCaptureHolder.current

        registry.setPointer(node, route: InputHandlerRoute(role: .drag,
                                                           priority: .capture,
                                                           debugName: "asset.drag")) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                app.store.dispatch(.beginAssetDrag(asset.dragPayload()))
                app.store.dispatch(.updateAssetDragCursor(x: event.x, y: event.y))
                capture?.acquire(node)
                return .handled
            case .up:
                _ = app.handleAssetDrop(at: event.x, cursorY: event.y)
                capture?.release()
                return .handled
            }
        }

        registry.setMotion(node, route: InputHandlerRoute(role: .drag,
                                                          priority: .capture,
                                                          debugName: "asset.drag")) { event, _ in
            if app.store.state.activeAssetDrag != nil {
                app.store.dispatch(.updateAssetDragCursor(x: event.x, y: event.y))
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
