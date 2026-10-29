import AssetPipeline
import EditorCore
import CoveUI
import CoveUIRuntime

struct MeshEditControls: View {
    let app: EditorApplication
    @State private var isPresented = false

    var body: some View {
        let model = app.meshEditing
        Popover(isPresented: $isPresented,width: 200,surface: .content,overflow: .flip,
                onKey: viewportPopoverDismissOnEscape($isPresented)) {
            ViewportMenuTrigger(label: L(model.mode.title),isActive: model.isEditing, isCompact: model.hasInteractiveEdit)
                .accessibility { $0.label = L("Editing Mode"); $0.value = L(model.mode.title) }
        } content: {
            Menu(EditorMeshSelectionMode.allCases.map { mode in
                .item(MenuItem(id: "mesh-mode-\(mode.rawValue)",title: L(mode.title),
                               shortcut: shortcut(mode),isEnabled: mode == .object || model.canEnter,
                               isSelected: model.mode == mode,action: { _ = model.setMode(mode) }))
            },width: 200,onItemActivated: { isPresented = false })
        }
        .debugName("mesh-mode-menu")
    }

    private func shortcut(_ mode: EditorMeshSelectionMode) -> String {
        switch mode { case .object: "Tab"; case .vertex: "1"; case .edge: "2"; case .face: "3" }
    }
}

struct MeshOperationsMenu: View {
    let app: EditorApplication
    @State private var isPresented = false

    var body: some View {
        let model = app.meshEditing
        Popover(isPresented: $isPresented,width: 248,surface: .content,overflow: .flip,
                onKey: viewportPopoverDismissOnEscape($isPresented)) {
            ViewportMenuTrigger(icon: UIIcons.Action.moreHorizontal)
                .tooltip(L("Mesh Tools")).accessibility { $0.label = L("Mesh Tools") }
        } content: {
            Menu(entries(model),width: 248,maxVisibleRows: 10,onItemActivated: { isPresented = false })
        }
        .debugName("mesh-tools-menu")
    }

    private func entries(_ model: EditorMeshEditing) -> [MenuEntry] {
        let faces = model.mode == .face && !model.selection.isEmpty && !model.hasInteractiveEdit
        let components = !model.selection.isEmpty && !model.hasInteractiveEdit
        return [
            .item(MenuItem(id: "mesh-loop-cut",title: L("Loop Cut and Slide"),shortcut: "Ctrl R",
                           isEnabled: model.mode == .edge && model.selection.count == 1 && !model.hasInteractiveEdit,
                           content: .init(icon: UIIcons.Action.sliders),action: { _ = model.beginLoopCut() })),
            .item(MenuItem(id: "mesh-inset",title: L("Inset Individual Faces"),shortcut: "I",isEnabled: faces,
                           content: .init(icon: UIIcons.Shape.square),action: { _ = model.beginInset() })),
            .item(MenuItem(id: "mesh-subdivide",title: L("Subdivide Faces"),isEnabled: faces,action: { _ = model.subdivideSelection() })),
            .item(MenuItem(id: "mesh-triangulate",title: L("Triangulate Faces"),isEnabled: faces,action: { _ = model.triangulateSelection() })),
            .item(MenuItem(id: "mesh-extrude",title: L("Extrude Region"),shortcut: "Shift E",isEnabled: faces,action: { _ = model.extrudeRegion() })),
            .item(MenuItem(id: "mesh-dissolve",title: L("Dissolve Edges"),shortcut: "Alt Delete",isEnabled: components && model.mode == .edge,
                           content: .init(icon: UIIcons.Action.unlink),action: { _ = model.dissolveSelection() })),
            .item(MenuItem(id: "mesh-delete",title: L("Delete Selected Components"),shortcut: "Delete",isEnabled: components,role: .destructive,
                           content: .init(icon: UIIcons.Action.trash),action: { _ = model.deleteSelection() })),
            .separator(id: "mesh-topology-apply"),
            .item(MenuItem(id: "mesh-apply-modifiers",title: L("Apply Modifiers to Mesh"),isEnabled: model.hasModifiers && !model.hasInteractiveEdit,
                           action: { _ = model.applyModifiers() })),
            .separator(id: "mesh-visibility"),
            .item(MenuItem(id: "mesh-xray",title: L("X-Ray"),shortcut: "Alt Z",isSelected: model.xray,action: { model.setXray(!model.xray) })),
            .item(MenuItem(id: "mesh-evaluated-wireframe",title: L("Modifier Wireframe"),isEnabled: model.hasModifiers,
                           isSelected: model.showsEvaluatedWireframe,action: { model.setEvaluatedWireframe(!model.showsEvaluatedWireframe) })),
        ]
    }
}

struct MeshTopologyStatus: View {
    let app: EditorApplication

    var body: some View {
        let model = app.meshEditing
        if let mesh = model.controlMesh() {
            Column(alignment: .leading,spacing: 2) {
                Text(L("Control Mesh") + " · \(mesh.positions.count)V · \(mesh.faces.count)F")
                    .font(.caption).foregroundColor(.onSurface)
                if model.hasModifiers, let id = model.entityID,
                   let index = app.scene.referencedAsset(for: id)?.meshIndex,
                   let evaluated = AssetRegistry.shared.polygonMesh(for: index) {
                    Text(L("Modifier Result") + " · \(evaluated.positions.count)V · \(evaluated.faces.count)F")
                        .font(.caption).foregroundColor(.onSurfaceVariant)
                }
            }
            .padding(horizontal: 8,vertical: 5).background(.surfaceSunken).cornerRadius(5)
            .debugName("mesh-topology-status")
        }
    }
}
