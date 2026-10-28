import EditorCore
import CoveUI
import CoveUIRuntime

struct ViewportToolMenu: View {
    let store: EditorStore
    let mode: EditorGizmoMode
    let isEnabled: Bool
    @State private var isPresented = false

    private static let tools: [(EditorGizmoMode,String,String)] = [
        (.none,"Pick","Q"),(.boxSelect,"Box Select","B"),(.translate,"Move","W"),(.rotate,"Rotate","E"),(.scale,"Scale","R")
    ]

    var body: some View {
        let title = Self.tools.first { $0.0 == mode }?.1 ?? "Pick"
        Popover(isPresented: $isPresented,isEnabled: isEnabled,width: 200,surface: .content,overflow: .flip,
                onKey: viewportPopoverDismissOnEscape($isPresented)) {
            ViewportMenuTrigger(label: L(title))
                .accessibility { $0.label = L("Tool"); $0.value = L(title) }
        } content: {
            Menu(Self.tools.map { value,title,key in
                .item(MenuItem(id: "viewport-tool-\(key.lowercased())",title: L(title),shortcut: key,isSelected: mode == value,
                               action: { store.dispatch(.setGizmoMode(value)) }))
            },width: 200,onItemActivated: { isPresented = false })
        }
        .debugName("viewport-tool-menu")
    }
}
