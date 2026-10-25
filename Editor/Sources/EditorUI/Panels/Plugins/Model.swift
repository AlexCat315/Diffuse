internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime
internal import PluginRuntime

/// Content a package describes, for a panel or a document view. The host draws
/// the sections, rows and actions in its own style and runs the package's commands.
struct PluginModelPanel: View, @unchecked Sendable {
    let app: EditorApplication
    private let state: PluginPanelState
    private let observed: Observed<PluginPanelState, PluginPanelState.Snapshot>

    init(app: EditorApplication, state: PluginPanelState) {
        self.app = app
        self.state = state
        observed = Observed(\.snapshot, on: state)
    }

    private var debugName: String {
        switch state.source {
        case let .panel(panel): "plugin-panel-" + panel.id
        case let .document(view, _): "plugin-document-" + view.id
        }
    }

    var body: some View {
        let snapshot = observed.wrappedValue
        Column(alignment: .leading, spacing: 0) {
            if let model = snapshot.model {
                if !model.actions.isEmpty { toolbar(model.actions, busy: snapshot.isLoading) }
                if model.sections.contains(where: { !$0.items.isEmpty }) {
                    ScrollView(.vertical, scrollbarGutter: .stable) {
                        Column(alignment: .leading, spacing: 0) {
                            model.sections.map { AnyView(section($0)) }
                        }.padding(vertical: 4).frame(width: .percent(100), minWidth: 0)
                    }.flex().frame(minWidth: 0, minHeight: 0)
                } else if let empty = model.empty {
                    TaskEmptyState(empty)
                }
            } else if let failure = snapshot.failure {
                TaskEmptyState(failure)
            } else {
                Box(direction: .column, alignItems: .center, justifyContent: .center) { Spinner(size: 12) }
                    .flex().frame(width: .percent(100), minWidth: 0, minHeight: 0)
            }
        }
        .frame(minWidth: 0, minHeight: 0)
        .debugName(debugName)
    }

    private func toolbar(_ actions: [PanelModel.Action], busy: Bool) -> some View {
        EditorPanelToolbar(spacing: 4) {
            Spacer(minLength: 0)
            if busy { Spinner(size: 10) }
            actions.map { action in
                AnyView(Button(action.title) { run(action.command, action.arguments) }
                    .buttonStyle(EditorChromeButtonStyle(height: 22)).debugName("plugin-action-" + action.command))
            }
        }
    }

    private func section(_ section: PanelModel.Section) -> some View {
        Column(alignment: .leading, spacing: 0) {
            if let title = section.title {
                Text(title.uppercased(), lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted)
                    .padding(EdgeInsets(top: 8, leading: 12, bottom: 2, trailing: 12))
            }
            section.items.map { AnyView(row($0)) }
        }.frame(width: .percent(100), minWidth: 0)
    }

    @ViewBuilder
    private func row(_ item: PanelModel.Item) -> some View {
        let content = Row(alignment: .center, spacing: 8) {
            Text(item.title, lineLimit: 1).font(.body).foregroundColor(Self.color(item.tone))
                .flex(0, shrink: 1).frame(minWidth: 0)
            Text(item.detail ?? "", lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted)
                .flex(1, shrink: 1).frame(minWidth: 0)
            if let badge = item.badge { EditorPanelBadge(badge) }
        }.padding(horizontal: 12).frame(width: .percent(100), height: .points(24), minWidth: 0).debugName("plugin-row")
        if let command = item.command {
            Button(action: { run(command, item.arguments) }) { content }
                .buttonStyle(.plain).frame(width: .percent(100))
        } else {
            content
        }
    }

    private func run(_ command: String, _ arguments: PluginJSON?) {
        PluginCommandRunner.run(pluginID: state.source.pluginID, name: command, arguments: arguments, app: app)
    }

    private static func color(_ tone: PanelModel.Tone?) -> SemanticColorRef {
        switch tone ?? .normal {
        case .normal: .onSurface
        case .muted: .onSurfaceMuted
        case .accent: .accent
        case .success: .success
        case .warning: .warning
        case .danger: .error
        }
    }
}
