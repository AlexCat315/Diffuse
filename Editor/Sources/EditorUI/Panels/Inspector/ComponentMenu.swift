internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime

/// Reset and Remove live on the component card they act on, so the user never
/// has to pick the component again from a list.
struct InspectorComponentMenu: View {
    let typeID: String
    let title: String
    let entityIDs: Set<UInt64>
    let scene: EditorSceneAdapter
    let store: EditorStore
    @State private var isPresented = false

    var body: some View {
        Popover(isPresented: $isPresented, width: 200, placement: .bottomTrailing, surface: .content, overflow: .flip) {
            Icon(UIIcons.Action.moreHorizontal, size: 13, color: .onSurfaceMuted)
                .frame(width: 24, height: 24)
                .accessibility { $0.label = title }
        } content: {
            Menu([
                .item(MenuItem(id: "reset", title: L("Reset Component")) { perform(reset: true) }),
                .item(MenuItem(id: "remove", title: L("Remove Component"), role: .destructive) { perform(reset: false) }),
            ], width: 200, onItemActivated: { isPresented = false })
        }.debugName("inspector-component-menu-\(typeID)")
    }

    private func perform(reset: Bool) {
        let succeeded = reset ? scene.resetComponent(typeID, on: entityIDs)
            : scene.removeComponent(typeID, from: entityIDs)
        guard !succeeded else { return }
        store.dispatch(.appendConsoleMessage(reset ? "Could not reset component" : "Could not remove component",
                                             severity: .error, detail: title))
    }
}
