internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime
internal import PluginRuntime

/// A plugin view, for a panel or a document: the component tree its package
/// returned, drawn by the host. A failed call keeps the last tree and says why.
struct PluginView: View, @unchecked Sendable {
    private let session: PluginViewSession
    private let observed: Observed<PluginViewSession, PluginViewSession.Snapshot>
    private let values: Observed<PluginViewSession, [String: PluginJSON]>

    init(session: PluginViewSession) {
        self.session = session
        observed = Observed(\.snapshot, on: session)
        values = Observed(\.values, on: session)
    }

    private var debugName: String {
        switch session.source {
        case let .panel(panel): "plugin-panel-" + panel.id
        case let .document(view, _): "plugin-document-" + view.id
        }
    }

    var body: some View {
        let snapshot = observed.wrappedValue
        let _ = values.wrappedValue
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if let failure = snapshot.failure {
                Row(alignment: .center, spacing: 8) {
                    Icon(UIIcons.Status.alertTriangle, size: 12, color: .error)
                    Text(failure, lineLimit: 2).font(.caption).foregroundColor(.error).flex().frame(minWidth: 0)
                }.padding(horizontal: 12, vertical: 6).background(SemanticColorRef.error.opacity(0.10))
                    .debugName("plugin-view-failure")
            }
            if let ui = snapshot.ui {
                PluginNodeRenderer(session: session).render(ui).flex().frame(minWidth: 0, minHeight: 0)
            } else if snapshot.failure == nil {
                Box(direction: .column, alignItems: .center, justifyContent: .center) { Spinner(size: 12) }
                    .flex().frame(width: .percent(100), minWidth: 0, minHeight: 0)
            }
        }
        .frame(minWidth: 0, minHeight: 0)
        .debugName(debugName)
    }
}
