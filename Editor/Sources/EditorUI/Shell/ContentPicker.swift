internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime

extension EditorContent {
    var icon: BundleImageResource {
        switch self {
        case .scene: UIIcons.Editor.box
        case .files: UIIcons.Editor.code
        case .timeline: UIIcons.Media.video
        }
    }
}

/// What the workbench is editing, and the way to pick something else. Only
/// one kind of content shows at a time, so the others wait in this menu.
struct EditorContentPicker: View {
    let app: EditorApplication
    let content: EditorContent
    let onCommand: (EditorCommand) -> Void
    @State private var isPresented = false
    private let surfaceObject: EditorAssistantSurface
    private var surface: Observed<EditorAssistantSurface, EditorAssistantSurface.State>

    init(app: EditorApplication, content: EditorContent, onCommand: @escaping (EditorCommand) -> Void) {
        self.app = app
        self.content = content
        self.onCommand = onCommand
        let surface = EditorAssistantSurface.of(app)
        surfaceObject = surface
        self.surface = Observed(\.state, on: surface)
    }

    @ViewBuilder
    var body: some View {
        // The agent view shows its own canvas; the picker belongs to the workbench.
        Box(direction: .row, alignItems: .center, spacing: 0) {
            if surfaceObject.view == .make {
                Popover(isPresented: $isPresented, width: 180, surface: .content, overflow: .flip) {
                    Row(alignment: .center, spacing: 6) {
                        Icon(content.icon, size: 12, color: .onSurfaceVariant)
                        Text(L(content.title), lineLimit: 1).font(.label).foregroundColor(.onSurface)
                        Icon(UIIcons.Navigation.chevronDown, size: 9, color: .onSurfaceMuted)
                    }.padding(horizontal: 8).frame(height: 26).background(.surfaceVariant).cornerRadius(7)
                        .accessibility { $0.label = L(content.title) }
                } content: {
                    Menu(EditorContent.allCases.map { item in
                        .item(MenuItem(id: item.rawValue, title: L(item.title), isSelected: item == content, action: {
                            isPresented = false
                            onCommand(.showContent(item))
                        }))
                    }, width: 180)
                }.debugName("editor-content-picker")
            }
        }
    }
}
