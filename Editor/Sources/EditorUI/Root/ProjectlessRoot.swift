internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime

/// The agent view while no project is open: the same title bar, task column and
/// composer, with nothing in them yet. Projects are added from the column's
/// Projects heading; the composer waits for one.
struct EditorProjectlessRoot: View {
    let context: EditorLaunchContext
    private var failure: Observed<EditorLaunchContext, String?>

    init(context: EditorLaunchContext) {
        self.context = context
        failure = Observed(\.openFailure, on: context)
    }

    var body: some View {
        let context = context
        let open = { MainActor.assumeIsolated { context.requestOpenFolder() } }
        return LayerRoot {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                EditorCanvasChrome {
                    ImmersiveWindowTitleBar(height: 40) {
                        Row(alignment: .center, spacing: 10) {
                            WindowDragRegion().flex().frame(minWidth: 8)
                            viewSwitch
                            WindowDragRegion().flex().frame(minWidth: 8)
                        }.frame(width: .percent(100), minWidth: 0).flex(1, shrink: 1)
                    }.frame(height: 40)
                }
                Box(direction: .row, alignItems: .stretch, spacing: 6) {
                    taskColumn(open: open).frame(width: 232).flex(0, shrink: 0)
                    thread.flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
                }.padding(EdgeInsets(leading: 6, bottom: 6, trailing: 6)).flex().frame(minWidth: 0, minHeight: 0)
            }.background(.background).flex()
        }
    }

    /// The workbench needs a project, so only the agent side of the switch is live.
    private var viewSwitch: some View {
        Row(alignment: .center, spacing: 2) {
            Row(alignment: .center, spacing: 6) {
                Icon(UIIcons.Editor.code, size: 12, color: .onSurfaceMuted)
                Text(L("Workbench")).font(.label).foregroundColor(.onSurfaceMuted)
            }.padding(horizontal: 12).frame(height: 26)
            Row(alignment: .center, spacing: 6) {
                Icon(UIIcons.Status.sparkles, size: 12, color: EditorThemeTokens.assistantColor)
                Text(L("Agent")).font(.label)
            }.padding(horizontal: 12).frame(height: 26).background(SemanticColorRef.surfaceRaised).cornerRadius(7)
        }.padding(2).background(.surfaceSunken).cornerRadius(9).debugName("editor-view-switch")
    }

    private func taskColumn(open: @escaping () -> Void) -> some View {
        Column(alignment: .leading, spacing: 2) {
            Button(isEnabled: false, action: {}) {
                Row(alignment: .center, spacing: 8) {
                    Icon(UIIcons.Action.plus, size: 13, color: .onSurfaceMuted)
                    Text(L("New Task")).font(.label).foregroundColor(.onSurfaceMuted)
                }.padding(horizontal: 10).frame(width: .percent(100), height: .points(32))
            }.buttonStyle(.ghost).frame(width: .percent(100)).debugName("editor-agent-new-task")
            Row(alignment: .center, spacing: 4) {
                Text(L("Projects")).font(.caption).foregroundColor(.onSurfaceMuted).flex(1, shrink: 1)
                Button(icon: .resource(UIIcons.Action.plus), size: 11, tooltip: L("Open Folder..."), action: open)
                    .buttonStyle(EditorChromeButtonStyle(height: 22)).debugName("projectless-open-folder")
            }.padding(EdgeInsets(top: 14, leading: 10, bottom: 4, trailing: 4))
            if let failure = failure.wrappedValue {
                Text(failure).font(.caption).foregroundColor(.error).padding(horizontal: 10, vertical: 6)
            }
            Spacer(minLength: 0)
        }.padding(EdgeInsets(top: 4)).flex().frame(minWidth: 0, minHeight: 0)
            .debugName("editor-agent-tasks")
    }

    private var thread: some View {
        Box(direction: .column, alignItems: .center, spacing: 0) {
            Spacer(minLength: 0)
            Column(alignment: .leading, spacing: 8) {
                Text(L("Describe what you want to do…")).font(.body).foregroundColor(.onSurfaceMuted)
                    .frame(width: .percent(100), minHeight: 48)
                Row(alignment: .center, spacing: 5) {
                    Spacer(minLength: 0)
                    Button(icon: .resource(UIIcons.Navigation.arrowUp), size: 13, isEnabled: false, tooltip: L("Send")) {}
                        .buttonStyle(EditorChromeButtonStyle(height: 26, agent: true))
                }.frame(width: .percent(100), minWidth: 0)
            }.padding(10).background(.surfaceSunken).cornerRadius(10).border(.borderStrong, width: 1)
                .frame(width: .percent(100), maxWidth: 760).padding(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
                .debugName("editor-agent-composer")
        }.flex().frame(minWidth: 0, minHeight: 0).background(.surface).cornerRadius(10).clipped()
            .debugName("editor-agent-thread")
    }
}
