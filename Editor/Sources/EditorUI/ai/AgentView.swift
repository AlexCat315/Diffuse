internal import EditorCore
private import Foundation
internal import CoveUI
internal import CoveUIRuntime
internal import CoveUIWorkspace

/// The agent view: projects and their tasks on the left, the conversation at
/// the center. The canvas joins only for what the agent is working on, or when
/// picked from the strip on the right; it is the same content the workbench edits.
struct EditorAgentView: View {
    let app: EditorApplication
    let controller: WorkspaceController
    let registry: WorkspacePanelRegistry
    let width: Float
    var projects: EditorLaunchContext?
    private var surface: Observed<EditorAssistantSurface, EditorAssistantSurface.State>

    init(app: EditorApplication, controller: WorkspaceController, registry: WorkspacePanelRegistry, width: Float,
         projects: EditorLaunchContext? = nil) {
        self.app = app
        self.controller = controller
        self.registry = registry
        self.width = width
        self.projects = projects
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
                    AgentTaskList(app: app, projects: projects).frame(width: 232).flex(0, shrink: 0)
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

/// The window's projects, newest work first under the one in front, and the
/// way to start more. Projects behind keep working and show it.
private struct AgentTaskList: View {
    let app: EditorApplication
    let projects: EditorLaunchContext?
    private var list: Observed<EditorLaunchContext, [EditorProjectEntry]>?

    init(app: EditorApplication, projects: EditorLaunchContext?) {
        self.app = app
        self.projects = projects
        list = projects.map { Observed(\.projects, on: $0) }
    }

    var body: some View {
        let app = app
        let store = app.store
        return Column(alignment: .leading, spacing: 2) {
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
            if let projects, let list {
                Row(alignment: .center, spacing: 4) {
                    Text(L("Projects")).font(.caption).foregroundColor(.onSurfaceMuted).flex(1, shrink: 1)
                    Button(icon: .resource(UIIcons.Action.plus), size: 11, tooltip: L("Open Folder...")) {
                        MainActor.assumeIsolated { projects.requestOpenFolder() }
                    }.buttonStyle(EditorChromeButtonStyle(height: 22)).debugName("editor-agent-open-folder")
                }.padding(EdgeInsets(top: 14, leading: 10, bottom: 4, trailing: 4))
                for entry in list.wrappedValue {
                    if entry.directory == app.projectDirectory {
                        AnyView(Text(entry.name, lineLimit: 1).truncated().font(.bodyStrong).foregroundColor(.onSurface)
                            .padding(EdgeInsets(top: 15, leading: 10, bottom: 4, trailing: 10)))
                        AnyView(tasks(store))
                    } else {
                        AnyView(AgentProjectRow(entry: entry, app: projects.bundle(for: entry.directory)?.app) {
                            MainActor.assumeIsolated {
                                do { try projects.activate(entry.directory) }
                                catch {
                                    EditorNotifications.of(app).post(error.localizedDescription, id: "open-project",
                                                                     tone: .danger, duration: nil)
                                }
                            }
                        })
                    }
                }
            } else {
                heading(URL(fileURLWithPath: app.projectDirectory).lastPathComponent)
                tasks(store)
            }
            Spacer(minLength: 0)
        }.padding(EdgeInsets(top: 4)).flex().frame(minWidth: 0, minHeight: 0)
            .debugName("editor-agent-tasks")
    }

    private func heading(_ name: String) -> some View {
        Text(name, lineLimit: 1).truncated().font(.caption)
            .foregroundColor(.onSurfaceMuted).padding(EdgeInsets(top: 14, leading: 10, bottom: 4))
    }

    @ViewBuilder private func tasks(_ store: EditorStore) -> some View {
        if !store.chatMessages.isEmpty || store.agentTasks.isEmpty {
            AgentTaskRow(title: store.chatMessages.first { $0.role == .user }?.text ?? L("New Task"),
                         detail: store.agentTasks.first.map { L($0.phase.title) }, selected: true)
        }
        for task in store.agentTasks.dropFirst(store.chatMessages.isEmpty ? 0 : 1) {
            AnyView(AgentTaskRow(title: task.prompt, detail: L(task.phase.title), selected: false))
        }
    }
}

/// A project behind the one in front. A loaded project shows when its agent is working.
private struct AgentProjectRow: View {
    let entry: EditorProjectEntry
    let app: EditorApplication?
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Row(alignment: .center, spacing: 8) {
                Text(entry.name, lineLimit: 1).truncated().font(.body).foregroundColor(.onSurfaceVariant)
                    .flex(1, shrink: 1).frame(minWidth: 0)
                if let app { AnyView(AgentProjectActivity(app: app)) }
            }.padding(horizontal: 10, vertical: 7).frame(width: .percent(100), minWidth: 0)
        }.buttonStyle(.ghost).frame(width: .percent(100)).padding(EdgeInsets(top: 8))
            .debugName("editor-agent-project-" + URL(fileURLWithPath: entry.directory).lastPathComponent)
    }
}

private struct AgentProjectActivity: View {
    let app: EditorApplication

    var body: some View {
        StoreScope(app.store) { store in
            let reviews = store.pendingConfirmationRequest?.questions.count ?? 0
            if reviews > 0 {
                Text("\(reviews)").font(.caption).foregroundColor(.onAccent)
                    .padding(horizontal: 5).frame(height: 16).background(EditorThemeTokens.assistantColor).cornerRadius(8)
                    .accessibility { $0.label = "\(reviews) \(L("Awaiting Review"))" }
            } else if store.agentTasks.contains(where: { $0.phase == .planning })
                        || store.chatMessages.contains(where: { AssistantThread.isActive($0) }) {
                Spinner(size: 11)
            }
        }
    }
}

private struct AgentTaskRow: View {
    let title: String
    let detail: String?
    let selected: Bool

    var body: some View {
        Column(alignment: .leading, spacing: 2) {
            Text(title, lineLimit: 1).truncated().font(.body).foregroundColor(selected ? .onSurface : .onSurfaceVariant)
            if let detail { Text(detail, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted) }
        }.padding(horizontal: 10, vertical: 7).frame(width: .percent(100), minWidth: 0)
            .background(selected ? SemanticColorRef.surfaceVariant : .clear).cornerRadius(8)
    }
}
