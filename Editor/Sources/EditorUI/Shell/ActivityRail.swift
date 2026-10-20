internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime
internal import GuavaUIWorkspace

struct EditorActivityRail: View {
    let app: EditorApplication
    let controller: WorkspaceController
    let onCommand: (EditorCommand) -> Void
    @State private var revision: UInt64 = 0
    @State private var observation = DockObservation()

    var body: some View {
        let _ = revision
        let _ = observation.bind(controller, to: $revision)
        Column(alignment: .center, spacing: 0) {
            if controller.document.panels["hierarchy"] != nil {
                panel(UIIcons.Text.list, title: L("Outline"), id: "hierarchy")
            }
            action(UIIcons.Action.search, title: L("Search")) {
                onCommand(.showCommandPalette(.resources))
            }.debugName("editor-rail-search")
            panel(UIIcons.Status.sparkles, title: L("Agent"), id: "intent-input", agent: true)
            panel(UIIcons.Editor.gitCommit, title: L("Session Journal"), id: "journal")
            if controller.document.panels["assets"] != nil {
                panel(UIIcons.File.folder, title: L("Assets"), id: "assets")
            }
            Spacer(minLength: 0)
            panel(UIIcons.Layout.panelBottom, title: L("Console"), id: "console")
            action(UIIcons.Action.settings, title: L("Settings")) { onCommand(.openSettings) }
                .debugName("editor-rail-settings")
        }.padding(vertical: 8).frame(width: 44)
            .background(.surfaceRaised).debugName("editor-activity-rail")
    }

    private func panel(_ icon: BundleImageResource, title: String, id: WorkspacePanelID,
                       agent: Bool = false) -> some View {
        let group = controller.document.groupContaining(panelID: id)
        let selected = group?.activePanelID == id && group?.isCollapsed == false
        return Button(icon: .resource(icon), size: 17, isSelected: selected, tooltip: title) {
            onCommand(.showPanel(id.rawValue))
        }.buttonStyle(ActivityButtonStyle(agent: agent))
            .accessibility { $0.label = title; $0.state.isSelected = selected }
            .debugName("editor-rail-" + id.rawValue)
    }

    private func action(_ icon: BundleImageResource, title: String, perform: @escaping () -> Void) -> some View {
        Button(icon: .resource(icon), size: 17, tooltip: title, action: perform)
            .buttonStyle(ActivityButtonStyle())
            .accessibility { $0.label = title }
    }
}

private struct ActivityButtonStyle: ButtonStyle {
    var agent = false

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let colors = configuration.theme.colors
        let ink = agent ? configuration.theme.extensions[EditorChromeTokens.self].agent : colors.onSurfaceVariant
        Row(alignment: .center, spacing: 4) {
            Box {}.frame(width: 2, height: 16)
                .background(configuration.isSelected ? colors.accent : .clear).cornerRadius(1)
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                AnyView(configuration.label).foregroundColor(configuration.isSelected && !agent ? colors.onSurface : ink)
            }.frame(width: 32, height: 32)
                .background(configuration.isPressed ? colors.stateLayerPressed
                    : configuration.isSelected ? colors.surfaceVariant
                    : configuration.isHovered ? colors.stateLayerHover : .clear)
                .cornerRadius(8)
                .border(configuration.isFocused ? colors.focusRing : .clear, width: 1)
        }.padding(EdgeInsets(trailing: 6)).frame(width: 44, height: 36)
    }
}

private final class DockObservation {
    private weak var controller: WorkspaceController?
    private var token: WorkspaceController.SubscriptionToken?

    func bind(_ next: WorkspaceController, to revision: Binding<UInt64>) {
        if controller === next { return }
        if let token { controller?.unsubscribe(token) }
        controller = next
        token = next.subscribe { revision.wrappedValue = $0.version }
    }

    deinit { if let token { controller?.unsubscribe(token) } }
}
