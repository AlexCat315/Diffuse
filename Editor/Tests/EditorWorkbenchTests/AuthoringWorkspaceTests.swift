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
    private final class ResizingTitle: View {
        let app: EditorApplication
        @State private var width: Float = 1280
        init(app: EditorApplication) { self.app = app }
        var body: some View { EditorTitleBar(app: app, width: width, onCommand: { _ in }) }
        func resize(to width: Float) { self.width = width }
    }

    @Test("Title controls retain their order when switching between menu, icon and labeled navigation")
    func titleResizeOrder() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path)
        defer { app.shutdown() }
        let harness = ResizingTitle(app: app)
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: harness)
        for width: Float in [1280, 390, 720, 1280] {
            harness.resize(to: width)
            for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 40) }
            let frames = graph.layoutSnapshot()
            let intent = try #require(frames.first { $0.debugName == "editor-intent-bar" })
            let spaces = try #require(frames.first { $0.debugName == (width < 680 ? "editor-spaces-menu" : "editor-spaces") })
            let playback = try #require(frames.first { $0.debugName == "editor-playback-toolbar" })
            #expect(intent.absoluteFrame.maxX <= spaces.absoluteFrame.minX)
            #expect(spaces.absoluteFrame.maxX <= playback.absoluteFrame.minX)
        }
    } }

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
        let catalog = EditorCommandCatalog.make(EditorCommandContext(app: app))
        #expect(!catalog.menus.contains { $0.id == "run" })
        #expect(catalog.entries.contains { $0.id == "layout.modelingSculpt" })
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
            graph.computeLayout(width: 1280, height: 800)
        }
        settle()
        let frames = graph.layoutSnapshot()
        #expect(controller.document.groups["trailing"]?.panels == ["inspector", "intent-input", "journal"])
        let tabs = try #require(frames.first { $0.debugName == "workspace-tabs-scroll-trailing" })
        for id in ["inspector", "intent-input", "journal"] {
            let tab = try #require(frames.first { $0.debugName == "workspace-tab-\(id)" })
            #expect(tab.absoluteFrame.minX >= tabs.absoluteFrame.minX)
            #expect(tab.absoluteFrame.maxX <= tabs.absoluteFrame.maxX)
        }
        #expect(frames.contains { $0.debugName == "editor-title-menu" } == (EditorMenuPresentation.current == .titleBar))
        #expect(frames.contains { $0.debugName == "editor-status-problems" })
        #expect(frames.contains { $0.debugName == "editor-status-agent" })
        let title = try #require(frames.first { $0.debugName == "editor-title-bar" })
        #expect(title.absoluteFrame.height == 40)
        let rail = try #require(frames.first { $0.debugName == "editor-activity-rail" })
        #expect(rail.absoluteFrame.width == 44)
        #expect(rail.absoluteFrame.minY == 41)
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

    @Test("Title controls stay inside narrow and wide windows with either menu presentation",
          arguments: [Float(390), Float(720), Float(1280), Float(1600)], [EditorMenuPresentation.native, .titleBar])
    func titleWidths(width: Float, menu: EditorMenuPresentation) throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path)
        defer { app.shutdown() }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: EditorTitleBar(app: app, width: width, menuPresentation: menu, onCommand: { _ in })
            .theme(EditorVisualTheme.make(dark: true)))
        for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 40) }
        let frames = graph.layoutSnapshot()
        for name in ["editor-title-menu", "editor-project", "editor-intent-bar", "editor-spaces", "editor-spaces-menu",
                     "editor-playback-toolbar"] {
            if let frame = frames.first(where: { $0.debugName == name })?.absoluteFrame {
                #expect(frame.minX >= 0 && frame.maxX <= CGFloat(width) + 1, "\(name) overflow at \(width)")
                #expect(frame.minY >= 0 && frame.maxY <= 40)
            }
        }
        let titleMenu = frames.first { $0.debugName == "editor-title-menu" }
        if menu == .titleBar {
            // The command tree leads the title bar, before the project switcher.
            let project = try #require(frames.first { $0.debugName == "editor-project" })
            #expect(try #require(titleMenu).absoluteFrame.maxX <= project.absoluteFrame.minX)
        } else {
            #expect(titleMenu == nil)
        }
        let title = try #require(frames.first { $0.debugName == "editor-title-bar" })
        #expect(title.absoluteFrame.height == 40)
    } }

    @Test("The activity rail follows Space switches and panel activation")
    func railFollowsLayout() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path)
        defer { app.shutdown() }
        let registry = EditorRootViewFactory.makeRegistry(app: app)
        let controller = WorkspaceController(document: EditorWorkspaceDefaults.makeDocument(
            mode: .documents, preset: .documentsDefault, registry: registry))
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: EditorActivityRail(app: app, controller: controller, onCommand: { _ in }))
        func rail() -> [String: Bool] {
            for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 44, height: 600) }
            var result: [String: Bool] = [:]
            func visit(_ node: Node) {
                if let name = node.attachments[LayoutDebugAttachmentKey.debugName] as? String, name.hasPrefix("editor-rail-") {
                    result[name] = node.accessibility?.state.isSelected ?? false
                }
                node.children.forEach(visit)
            }
            if let root = graph.tree.root { visit(root) }
            return result
        }
        #expect(rail()["editor-rail-files"] != nil)
        #expect(rail()["editor-rail-hierarchy"] == nil)

        app.store.dispatch(.setWorkspaceMode(.level))
        EditorRootViewFactory.resetLayout(into: controller, for: .level, preset: .levelDefault, registry: registry)
        let level = rail()
        #expect(level["editor-rail-files"] == nil)
        #expect(level["editor-rail-hierarchy"] != nil)

        EditorRootViewFactory.activatePanel("journal", in: controller)
        #expect(rail()["editor-rail-journal"] == true)
        #expect(rail()["editor-rail-intent-input"] == false)
    } }

    @Test("Scoped palette opens with its prefix, and closing removes the card and its modal scope")
    func paletteScopeAndClose() throws { try WorkbenchUITestSupport.withEnvironment { _, focus in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path)
        defer { app.shutdown() }
        let registry = EditorRootViewFactory.makeRegistry(app: app)
        let controller = WorkspaceController(document: EditorWorkspaceDefaults.makeDocument(
            mode: .level, preset: .levelDefault, registry: registry))
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: EditorRootView(app: app, controller: controller, registry: registry))
        func settle() {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 1280, height: 800)
        }
        settle()
        EditorCommandDispatcher.handle(.showCommandPalette(.commands), app: app, controller: controller, registry: registry)
        for _ in 0..<3 { settle() }
        #expect(app.store.commandPaletteQuery.stringValue == ">")
        #expect(graph.layoutSnapshot().contains { $0.debugName == "command-palette-card" })
        #expect(focus.hasModalScope)

        app.store.dispatch(.setCommandPaletteVisible(false))
        settle()
        #expect(!graph.layoutSnapshot().contains { $0.debugName == "command-palette-card" })
        #expect(!focus.hasModalScope)
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

    @Test("Pending review stays inside Agent and can be discarded without losing the draft")
    func inlineReview() throws { try WorkbenchUITestSupport.withEnvironment { interactions, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: true)
        defer { app.shutdown() }
        let entityID = try #require(app.store.selectedEntityID)
        app.submitDeleteSelectedEntityIntent()
        #expect(app.store.pendingConfirmationRequest != nil)
        let draft = AgentDraft()
        draft.text = "Next thought"
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: IntentInputPanel(app: app, draft: draft))
        graph.computeLayout(width: 324, height: 720)
        #expect(graph.layoutSnapshot().contains { $0.debugName == "editor-agent-review" })
        try WorkbenchUITestSupport.activate("editor-agent-discard-review", in: graph.tree.root, registry: interactions)
        for _ in 0..<3 { graph.recomposer.commitAll() }
        #expect(app.store.pendingConfirmationRequest == nil)
        #expect(app.scene.entitySummary(id: entityID) != nil)
        #expect(draft.text.stringValue == "Next thought")
        #expect(!graph.layoutSnapshot().contains { $0.debugName == "editor-agent-review" })
    } }
}
