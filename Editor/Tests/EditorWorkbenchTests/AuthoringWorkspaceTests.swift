@testable import EditorUI
import EditorCore
import SceneRuntime
import ScriptRuntime
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace
import Testing

@Suite("Unified authoring workbench", .serialized)
@MainActor
struct AuthoringWorkspaceTests {
    @Test("Shell persistence round-trips authoring groups and defaults without interaction modes")
    func shellPersistence() throws {
        let workspace = EditorWorkspaceState {
            $0.mode = .animation
            $0.layoutPreset = .animationDefault
        }
        let data = try JSONEncoder().encode(EditorRootViewFactory.EditorShellState(workspace: workspace))
        let restored = try JSONDecoder().decode(EditorRootViewFactory.EditorShellState.self, from: data)
        #expect(restored.workspace == workspace)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let authored = try #require(fields["workspace"] as? [String: Any])
        #expect(Set(authored.keys) == ["mode", "layoutPreset"])
        let defaults = try JSONDecoder().decode(EditorRootViewFactory.EditorShellState.self, from: Data("{}".utf8))
        #expect(defaults.workspace == EditorWorkspaceState())
        let partial = Data(#"{"workspace":{"mode":"modeling"}}"#.utf8)
        let normalized = try JSONDecoder().decode(EditorRootViewFactory.EditorShellState.self, from: partial)
        #expect(normalized.workspace.layoutPreset == .modelingDefault)
    }

    @Test("Creation commands keep Agent reachable and exclude unavailable gameplay tools")
    func creationCommands() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path)
        defer { app.shutdown() }
        app.store.dispatch(.setWorkspaceMode(.modeling))
        let commands = EditorCommandSearch.commands(app: app)
        #expect(!commands.contains { $0.id == "scripts.show" || $0.id == "project.build" || $0.id.hasPrefix("playback.") })
        #expect(commands.contains { $0.id == "agent.show" })
        #expect(commands.contains { $0.id == "agent.review" })
        let model = EditorMenuModel.make(workspaceMode: .modeling, activeLayoutPreset: .modelingDefault,
                                        playbackState: .stopped)
        #expect(!model.menus.contains { $0.title == L("Build") })
        #expect(model.menus.contains { $0.title == L("Layout") })
        var registry = ComponentRegistry.builtIn
        registry.registerScriptCodec()
        #expect(!InspectorWorkspacePolicy.allows(registry["script"]!, in: .modeling))
        #expect(InspectorWorkspacePolicy.allows(registry["cloth"]!, in: .animation))
    } }

    @Test("Agent and properties share the scene, selection and existing custom docking")
    func contextSwitchAndFrames() throws { try WorkbenchUITestSupport.withEnvironment { interactions, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: true)
        defer { app.shutdown() }
        let registry = EditorRootViewFactory.makeRegistry(app: app)
        let document = EditorWorkspaceDefaults.makeDocument(mode: .level, preset: .levelDefault, registry: registry)
        let controller = WorkspaceController(document: document)
        let selected = app.store.selectedEntityIDs
        let identity = app.store.state.document.identity
        let revision = app.scene.revision
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: EditorRootView(app: app, controller: controller, registry: registry))
        func settle() {
            for _ in 0..<3 { graph.recomposer.commitAll() }
            graph.computeLayout(width: 1440, height: 900)
        }
        settle()
        let frames = graph.layoutSnapshot()
        #if !os(Linux)
        #expect(!frames.contains { $0.debugName == "editor-application-menu-bar" })
        #endif
        let title = try #require(frames.first { $0.debugName == "editor-title-bar" })
        #expect(title.absoluteFrame.height == 40)
        let rail = try #require(frames.first { $0.debugName == "editor-activity-rail" })
        #expect(rail.absoluteFrame.width == 44)
        #if !os(Linux)
        #expect(rail.absoluteFrame.minY == 41)
        #endif
        for name in ["workspace-panel-hierarchy", "workspace-panel-viewport", "workspace-panel-inspector", "workspace-panel-console"] {
            let frame = try #require(frames.first { $0.debugName == name })
            #expect(frame.absoluteFrame.width >= 220)
            #expect(frame.absoluteFrame.height >= 140)
        }
        try WorkbenchUITestSupport.activate("editor-rail-intent-input", in: graph.tree.root, registry: interactions)
        settle()
        #expect(controller.document.groups["trailing"]?.activePanelID == "intent-input")
        #expect(controller.document.groups["leading"] == document.groups["leading"])
        #expect(controller.document.slots == document.slots)
        #expect(graph.layoutSnapshot().contains { $0.debugName == "editor-agent-thread" })
        EditorCommandDispatcher.handle(.showPanel("inspector"), app: app, controller: controller,
                                       registry: registry, fromCommandPalette: true)
        settle()
        #expect(controller.document == document)
        #expect(app.store.selectedEntityIDs == selected)
        #expect(app.store.state.document.identity == identity)
        #expect(app.scene.revision == revision)
    } }

    @Test("Title controls stay inside narrow and wide windows", arguments: [Float(390), Float(720), Float(1280), Float(1600)])
    func titleWidths(width: Float) throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path)
        defer { app.shutdown() }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: EditorTitleBar(app: app, width: width, onCommand: { _ in })
            .theme(EditorVisualTheme.make(dark: true)))
        for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 40) }
        let frames = graph.layoutSnapshot()
        for name in ["editor-project", "editor-intent-bar", "editor-spaces", "editor-spaces-menu", "editor-playback-toolbar"] {
            if let frame = frames.first(where: { $0.debugName == name })?.absoluteFrame {
                #expect(frame.minX >= 0 && frame.maxX <= CGFloat(width) + 1, "\(name) overflow at \(width)")
                #expect(frame.minY >= 0 && frame.maxY <= 40)
            }
        }
        let title = try #require(frames.first { $0.debugName == "editor-title-bar" })
        #expect(title.absoluteFrame.height == 40)
    } }

    @Test("Agent draft survives context tab unmount and failed submission")
    func agentDraftRetention() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path)
        defer { app.shutdown() }
        let draft = AgentDraft()
        draft.text = "Keep this thought"
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: IntentInputPanel(app: app, draft: draft))
        graph.computeLayout(width: 324, height: 720)
        graph.install(root: Text("Properties"))
        graph.install(root: IntentInputPanel(app: app, draft: draft))
        graph.computeLayout(width: 324, height: 720)
        #expect(draft.text.stringValue == "Keep this thought")
        #expect(!app.submitNaturalLanguageIntent(draft.text.stringValue))
        #expect(draft.text.stringValue == "Keep this thought")
    } }
}
