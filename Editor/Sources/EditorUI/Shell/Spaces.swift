internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime

/// Navigation destinations over the existing authoring domains. Layout and
/// capability ownership stay in EditorCore rather than being copied into UI state.
enum EditorSpace: String, CaseIterable {
    case write, build, animate, cut, render

    init(mode: EditorWorkspaceMode) {
        switch mode {
        case .documents, .scripting: self = .write
        case .level: self = .build
        case .animation: self = .animate
        case .video: self = .cut
        case .modeling: self = .render
        }
    }

    var mode: EditorWorkspaceMode {
        switch self {
        case .write: .documents
        case .build: .level
        case .animate: .animation
        case .cut: .video
        case .render: .modeling
        }
    }

    var title: String {
        switch self {
        case .write: "Write"
        case .build: "Gameplay"
        case .animate: "Animate"
        case .cut: "Video"
        case .render: "Render"
        }
    }

    var icon: BundleImageResource {
        switch self {
        case .write: UIIcons.Editor.code
        case .build: UIIcons.Editor.box
        case .animate: UIIcons.Media.camera
        case .cut: UIIcons.Media.video
        case .render: UIIcons.Device.sun
        }
    }
}

struct EditorSpaceSwitcher: View {
    enum Presentation { case labels, icons, menu }
    let mode: EditorWorkspaceMode
    let presentation: Presentation
    let onCommand: (EditorMenuCommand) -> Void
    @State private var isPresented = false

    @ViewBuilder
    var body: some View {
        if presentation == .menu {
            let current = EditorSpace(mode: mode)
            Popover(isPresented: $isPresented, width: 200, surface: .content, overflow: .flip) {
                Row(alignment: .center, spacing: 5) {
                    Icon(current.icon, size: 14)
                    Icon(UIIcons.Navigation.chevronDown, size: 9)
                }.padding(horizontal: 8, vertical: 6).background(.surfaceVariant).cornerRadius(6)
                    .accessibility { $0.label = L(current.title) + " Space" }
            } content: {
                Menu(EditorSpace.allCases.map { space in
                    .item(MenuItem(id: space.rawValue, title: L(space.title), isSelected: current == space, action: {
                        isPresented = false
                        onCommand(.setWorkspaceMode(space.mode))
                    }))
                }, width: 200)
            }.debugName("editor-spaces-menu")
        } else {
            Row(alignment: .center, spacing: 1) {
                for space in EditorSpace.allCases {
                    AnyView(Button(isSelected: EditorSpace(mode: mode) == space,
                                   tooltip: L(space.title)) {
                        onCommand(.setWorkspaceMode(space.mode))
                    } label: {
                        Row(alignment: .center, spacing: 5) {
                            Icon(space.icon, size: 13)
                            if presentation == .labels { Text(L(space.title)) }
                        }
                    }.buttonStyle(EditorChromeButtonStyle(height: 24))
                        .accessibility { $0.label = L(space.title); $0.state.isSelected = EditorSpace(mode: mode) == space }
                        .debugName("editor-space-" + space.rawValue))
                }
            }.padding(2).background(.surfaceSunken).cornerRadius(8)
                .border(.divider, width: 1).debugName("editor-spaces")
        }
    }
}
