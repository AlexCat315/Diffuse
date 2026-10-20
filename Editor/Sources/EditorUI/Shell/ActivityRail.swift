internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime
internal import GuavaUIWorkspace

struct EditorActivityRail: View {
    let app: EditorApplication
    let controller: WorkspaceController
    let onCommand: (EditorMenuCommand) -> Void
    @State private var revision: UInt64 = 0
    @State private var observation = DockObservation()

    var body: some View {
        let _ = revision
        let _ = observation.bind(controller, to: $revision)
        Column(alignment: .center, spacing: 4) {
            if controller.document.panels["hierarchy"] != nil {
                panel(UIIcons.Text.list, title: L("Outline"), id: "hierarchy")
            }
            action(UIIcons.Action.search, title: L("Search")) {
                app.store.dispatch(.setCommandPaletteQuery("@"))
                onCommand(.showCommandPalette)
            }.debugName("editor-rail-search")
            panel(UIIcons.Status.sparkles, title: L("Agent"), id: "intent-input", agent: true)
            panel(UIIcons.Status.shieldCheck, title: L("Review"), id: "confirmation-host",
                  agent: app.store.pendingConfirmationRequest != nil)
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
        }.buttonStyle(EditorChromeButtonStyle(height: 32, agent: agent))
            .accessibility { $0.label = title; $0.state.isSelected = selected }
            .debugName("editor-rail-" + id.rawValue)
    }

    private func action(_ icon: BundleImageResource, title: String, perform: @escaping () -> Void) -> some View {
        Button(icon: .resource(icon), size: 17, tooltip: title, action: perform)
            .buttonStyle(EditorChromeButtonStyle(height: 32))
            .accessibility { $0.label = title }
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
