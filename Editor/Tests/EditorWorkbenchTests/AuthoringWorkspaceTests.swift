@testable import EditorApp
import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace
import Testing

@Suite("Functional authoring shells", .serialized)
@MainActor
struct AuthoringWorkspaceTests {
    @Test("Shell persistence round-trips the workspace group and normalizes defaults")
    func shellPersistence() throws {
        let workspace = EditorWorkspaceState {
            $0.mode = .animation
            $0.layoutPreset = .animationDefault
            $0.interactionMode = .agent
        }
        let shell = EditorRootViewFactory.EditorShellState(workspace: workspace)
        let data = try JSONEncoder().encode(shell)
        let restored = try JSONDecoder().decode(EditorRootViewFactory.EditorShellState.self, from: data)
        #expect(restored.workspace == workspace)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields["workspace"] is [String: Any])
        #expect(fields["workspaceMode"] == nil)
        let defaults = try JSONDecoder().decode(EditorRootViewFactory.EditorShellState.self, from: Data("{}".utf8))
        #expect(defaults.workspace == EditorWorkspaceState())
        let partial = Data(#"{"workspace":{"mode":"modeling","interactionMode":"agent"}}"#.utf8)
        let normalized = try JSONDecoder().decode(EditorRootViewFactory.EditorShellState.self, from: partial)
        #expect(normalized.workspace.layoutPreset == .modelingDefault)
        #expect(normalized.workspace.interactionMode == .agent)
    }

    @Test("Creation menus and search remove unavailable game commands")
    func creationCommands() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path)
        defer { app.shutdown() }
        app.store.dispatch(.setWorkspaceMode(.modeling))
        let commands = EditorCommandSearch.commands(app: app)
        #expect(!commands.contains { $0.id == "scripts.show" || $0.id == "project.build" || $0.id.hasPrefix("playback.") })
        #expect(commands.contains { $0.id == "interaction.agent" })
        let model = EditorMenuModel.make(workspaceMode: .modeling, activeLayoutPreset: .modelingDefault,
                                        playbackState: .stopped, interactionMode: .agent)
        #expect(!model.menus.contains { $0.title == L("Build") || $0.title == L("Layout") })
        #expect(!InspectorWorkspacePolicy.allows(.script, in: .modeling))
        #expect(InspectorWorkspacePolicy.allows(.cloth, in: .animation))
        #expect(!InspectorWorkspacePolicy.allows(.characterController, in: .animation))
    } }

    @Test("Agent task and conversation panels use independent collapsible docking")
    func agentDocking() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let controller = EditorAgentWorkspaceDefaults.makeController()
        #expect(controller.document.groups["leading"]?.isCollapsed == true)
        _ = controller.dispatch(.expand("leading"))
        #expect(controller.document.groups["leading"]?.isCollapsed == false)
        _ = controller.dispatch(.collapse("trailing"))
        #expect(controller.document.groups["trailing"]?.isCollapsed == true)
        #expect(controller.document.hasValidLayoutReferences)
    } }

    @Test("Manual and Agent shells preserve document, selection, and custom docking")
    func shellSwitchAndFrames() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "GUAVA_EDITOR_STATE_DIRECTORY"
        let previous = ProcessInfo.processInfo.environment[key]
        _ = WorkbenchUITestSupport.setEnvironmentValue(directory.appendingPathComponent("state").path, for: key)
        defer { _ = WorkbenchUITestSupport.setEnvironmentValue(previous, for: key) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: true)
        defer { app.shutdown() }
        let registry = EditorRootViewFactory.makeRegistry(app: app)
        let controller = EditorRootViewFactory.makeController(for: .level, preset: .levelDefault, registry: registry)
        _ = controller.dispatch(.collapse("trailing"))
        let layout = controller.document
        let selected = app.store.selectedEntityIDs
        let identity = app.store.state.document.identity
        let revision = app.scene.revision
        EditorCommandDispatcher.handle(.setInteractionMode(.agent), app: app, controller: controller,
                                       registry: registry, fromCommandPalette: true)
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: EditorRootView(app: app, controller: controller, registry: registry))
        graph.computeLayout(width: 1440, height: 900)
        let frames = graph.layoutSnapshot()
        let shell = try #require(frames.first { $0.debugName == "agent-workbench" })
        #expect(shell.absoluteFrame.width >= 1400)
        #expect(shell.absoluteFrame.height >= 750)
        for name in ["agent-preview", "agent-conversation"] {
            let frame = try #require(frames.first { $0.debugName == name })
            #expect(frame.absoluteFrame.width >= 200)
            #expect(frame.absoluteFrame.height >= 700)
        }
        #expect(!frames.contains { $0.debugName == "agent-task-list" })
        #expect(frames.contains { $0.debugName == "workspace-restore-leading-agent-tasks" })
        let viewport = try #require(frames.first { $0.debugName == "agent-scene-viewport" })
        #expect(viewport.absoluteFrame.width >= 700)
        #expect(viewport.absoluteFrame.height >= 650)
        EditorCommandDispatcher.handle(.setInteractionMode(.manual), app: app, controller: controller,
                                       registry: registry, fromCommandPalette: true)
        #expect(controller.document == layout)
        #expect(app.store.selectedEntityIDs == selected)
        #expect(app.store.state.document.identity == identity)
        #expect(app.scene.revision == revision)
        let shellState = try #require(EditorRootViewFactory.loadShellState())
        #expect(shellState.workspace.interactionMode == .manual)
    } }
}
