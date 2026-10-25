internal import EditorCore
private import Foundation
internal import GuavaUI
internal import GuavaUIRuntime
internal import GuavaUIWorkspace

/// The agent view: tasks on the left and the conversation at the center. The
/// canvas joins only for what the agent is working on, or when picked from the
/// strip on the right; it is the same content the workbench edits.
struct EditorAgentView: View {
    let app: EditorApplication
    let controller: WorkspaceController
    let registry: WorkspacePanelRegistry
    let width: Float
    private var surface: Observed<EditorAssistantSurface, EditorAssistantSurface.State>

    init(app: EditorApplication, controller: WorkspaceController, registry: WorkspacePanelRegistry, width: Float) {
        self.app = app
        self.controller = controller
        self.registry = registry
        self.width = width
        surface = Observed(\.state, on: EditorAssistantSurface.of(app))
    }

    var body: some View {
        StoreScope(app.store) { store in
            let shown: EditorContent? = switch surface.wrappedValue.canvas {
            case .follow: store.agentCanvas
            case .hidden: nil
            case let .content(content): content
            }
            let showsTasks = width >= 1100
            let canvasWidth: Float = shown == nil ? 36 : max(320, width * 0.4)
            let threadWidth = width - canvasWidth - (showsTasks ? 232 + 6 : 0) - 18
            Box(direction: .row, alignItems: .stretch, spacing: 6) {
                if showsTasks {
                    AgentTaskList(app: app).frame(width: 232).flex(0, shrink: 0)
                }
                AssistantThread(app: app, inset: max(20, (threadWidth - 760) / 2))
                    .flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
                    .cornerRadius(10).clipped()
                if let shown {
                    canvas(shown).frame(width: .points(canvasWidth)).flex(0, shrink: 0)
                } else {
                    strip.frame(width: .points(canvasWidth)).flex(0, shrink: 0)
                }
            }.padding(EdgeInsets(leading: 6, bottom: 6, trailing: 6)).flex().frame(minWidth: 0, minHeight: 0)
                .debugName("editor-agent-view")
        }
    }

    /// Nothing is open beside the thread; each kind of content is one click away.
    private var strip: some View {
        Column(alignment: .center, spacing: 4) {
            for item in EditorContent.allCases {
                AnyView(Button(icon: .resource(item.icon), size: 15, tooltip: L(item.title)) {
                    EditorAssistantSurface.of(app).showCanvas(.content(item))
                }.buttonStyle(EditorChromeButtonStyle(height: 30)).debugName("editor-agent-show-" + item.rawValue))
            }
        }.padding(EdgeInsets(top: 4)).debugName("editor-agent-canvas-strip")
    }

    private func canvas(_ content: EditorContent) -> some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Row(alignment: .center, spacing: 4) {
                for item in EditorContent.allCases {
                    AnyView(Button(icon: .resource(item.icon), size: 13, isSelected: item == content, tooltip: L(item.title)) {
                        EditorAssistantSurface.of(app).showCanvas(.content(item))
                    }.buttonStyle(EditorChromeButtonStyle(height: 26)).debugName("editor-agent-canvas-" + item.rawValue))
                }
                Text(L(content.title)).font(.label).foregroundColor(.onSurface).padding(EdgeInsets(leading: 4))
                Spacer(minLength: 0)
                Button(icon: .resource(UIIcons.Navigation.maximize), size: 12, tooltip: L("Open in Workbench")) {
                    EditorContentFollower.show(content, app: app, controller: controller)
                    EditorAssistantSurface.of(app).show(.make)
                }.buttonStyle(EditorChromeButtonStyle(height: 26)).debugName("editor-agent-canvas-make")
                Button(icon: .resource(UIIcons.Action.x), size: 12, tooltip: L("Hide")) {
                    EditorAssistantSurface.of(app).showCanvas(.hidden)
                }.buttonStyle(EditorChromeButtonStyle(height: 26)).debugName("editor-agent-canvas-hide")
            }.padding(horizontal: 8).frame(height: 38)
            registry.make(EditorContentFollower.panel(for: content)).flex().frame(minWidth: 0, minHeight: 0)
        }.background(.surface).cornerRadius(10).clipped().debugName("editor-agent-canvas")
    }
}

/// The work the agent has done this session, newest first, and the way to start more.
private struct AgentTaskList: View {
    let app: EditorApplication

    var body: some View {
        let store = app.store
        Column(alignment: .leading, spacing: 2) {
            Button {
                store.dispatch(.clearChatHistory)
                EditorAssistantSurface.of(app).showCanvas(.follow)
                EditorAssistantSurface.of(app).focus()
            } label: {
                Row(alignment: .center, spacing: 8) {
                    Icon(UIIcons.Action.plus, size: 13, color: .onSurfaceVariant)
                    Text(L("New Task")).font(.label).foregroundColor(.onSurface)
                }.padding(horizontal: 10).frame(width: .percent(100), height: .points(32))
            }.buttonStyle(.ghost).frame(width: .percent(100)).debugName("editor-agent-new-task")
            Text(URL(fileURLWithPath: app.projectDirectory).lastPathComponent).font(.caption)
                .foregroundColor(.onSurfaceMuted).padding(EdgeInsets(top: 14, leading: 10, bottom: 4))
            if !store.chatMessages.isEmpty || store.agentTasks.isEmpty {
                row(title: store.chatMessages.first { $0.role == .user }?.text ?? L("New Task"),
                    detail: store.agentTasks.first.map { L($0.phase.title) }, selected: true)
            }
            for task in store.agentTasks.dropFirst(store.chatMessages.isEmpty ? 0 : 1) {
                AnyView(row(title: task.prompt, detail: L(task.phase.title), selected: false))
            }
            Spacer(minLength: 0)
        }.padding(EdgeInsets(top: 4)).flex().frame(minWidth: 0, minHeight: 0)
            .debugName("editor-agent-tasks")
    }

    private func row(title: String, detail: String?, selected: Bool) -> some View {
        Column(alignment: .leading, spacing: 2) {
            Text(title, lineLimit: 1).truncated().font(.body).foregroundColor(selected ? .onSurface : .onSurfaceVariant)
            if let detail { Text(detail, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted) }
        }.padding(horizontal: 10, vertical: 7).frame(width: .percent(100), minWidth: 0)
            .background(selected ? SemanticColorRef.surfaceVariant : .clear).cornerRadius(8)
    }
}
