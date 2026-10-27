@testable import EditorUI
@testable import EditorCore
import PluginRuntime
import SceneRuntime
import ScriptRuntime
import Foundation
import CoveUICompose
import CoveUIRuntime
import CoveUIWorkspace
import Testing

@Suite("Unified authoring workbench", .serialized)
@MainActor
struct AuthoringWorkspaceTests {
    /// Bundled AI/agent support, as the editor loads it at launch.
    private static func enableAgent(in app: EditorApplication) throws {
        let plugin = try #require(BundledPlugins.plugin(id: "studio.ai"))
        let package = try PluginPackageLoader().load(at: plugin.package)
        app.pluginSession.providers = AIProviderCatalog(packages: [package])
        app.pluginSession.agents = AgentCatalog(packages: [package])
        app.pluginSession.editor.workbench.replace(WorkbenchCatalog(packages: [package]))
    }

    private final class ResizingTitle: View {
        let app: EditorApplication
        @State private var width: Float = 1280
        init(app: EditorApplication) { self.app = app }
        var body: some View { EditorTitleBar(app: app, width: width, onCommand: { _ in }) }
        func resize(to width: Float) { self.width = width }
    }

    @Test("Title controls keep their order as the window narrows and widens")
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
            let project = try #require(frames.first { $0.debugName == "editor-project" })
            let playback = try #require(frames.first { $0.debugName == "editor-playback-toolbar" })
            #expect(project.absoluteFrame.maxX <= playback.absoluteFrame.minX)
            #expect(!frames.contains { $0.debugName == "editor-intent-bar" || $0.debugName == "editor-presence" })
        }
    } }

    @Test("Shell persistence holds preferences, not what the window centers on")
    func shellPersistence() throws {
        let data = try JSONEncoder().encode(EditorRootViewFactory.EditorShellState(themeMode: .light))
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields["workspace"] == nil)
        let restored = try JSONDecoder().decode(EditorRootViewFactory.EditorShellState.self, from: data)
        #expect(restored.themeMode == .light)
        let defaults = try JSONDecoder().decode(EditorRootViewFactory.EditorShellState.self, from: Data("{}".utf8))
        #expect(defaults.themeMode == .dark)
    }

    @Test("Files keep Agent, playback and builds reachable without scene editing")
    func creationCommands() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path)
        defer { app.shutdown() }
        try Self.enableAgent(in: app)
        app.store.dispatch(.setContent(.files))
        let commands = EditorCommandSearch.commands(app: app)
        #expect(commands.contains { $0.id == "project.build" })
        #expect(!commands.contains { $0.id == "scene.save" })
        #expect(commands.contains { $0.id == "surface.studio.ai.assistant" && $0.title == "AI" })
        let catalog = EditorCommandCatalog.make(EditorCommandContext(app: app))
        #expect(catalog.menus.contains { $0.id == "run" })
        #expect(!catalog.menus.contains { $0.id == "world" })
    } }

    @Test("Make and Agent views share one project and leave the scene untouched")
    func contextSwitchAndFrames() throws { try WorkbenchUITestSupport.withEnvironment { interactions, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: true)
        defer { app.shutdown() }
        try Self.enableAgent(in: app)
        let registry = EditorRootViewFactory.makeRegistry(app: app)
        let document = EditorWorkspaceDefaults.makeDocument(registry: registry)
        let controller = WorkspaceController(document: document)
        let selected = app.store.selectedEntityIDs
        let identity = app.store.state.document.identity
        let revision = app.scene.revision
        #expect(EditorAssistantSurface.of(app).view == EditorStudioView("studio.ai.assistant"))
        EditorAssistantSurface.of(app).show(.make)
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: EditorRootView(app: app, controller: controller, registry: registry))
        func settle() {
            for _ in 0..<3 { graph.recomposer.commitAll() }
            graph.computeLayout(width: 1280, height: 800)
        }
        settle()
        let frames = graph.layoutSnapshot()
        #expect(controller.document.groups["leading"]?.panels == ["sidebar"])
        #expect(controller.document.groups["trailing"]?.panels == ["details"])
        // One pane per side: no tab strips there.
        #expect(!frames.contains { $0.debugName == "workspace-tabs-scroll-trailing" || $0.debugName == "workspace-tabs-scroll-leading" })
        #expect(frames.contains { $0.debugName == "editor-title-menu" } == (EditorMenuPresentation.current == .titleBar))
        #expect(frames.contains { $0.debugName == "editor-status-problems" })
        #expect(!frames.contains { $0.debugName == "editor-status-agent" })
        let title = try #require(frames.first { $0.debugName == "editor-title-bar" })
        #expect(title.absoluteFrame.height == 40)
        let rail = try #require(frames.first { $0.debugName == "editor-activity-rail" })
        #expect(rail.absoluteFrame.width == 44)
        #expect(rail.absoluteFrame.minY == 40)
        for name in ["workspace-panel-sidebar", "workspace-panel-viewport", "workspace-panel-details", "workspace-panel-console"] {
            let frame = try #require(frames.first { $0.debugName == name })
            #expect(frame.absoluteFrame.width >= 220)
            #expect(frame.absoluteFrame.height >= 140)
        }
        // Make is yours: no agent panel anywhere, only the switch in the title bar.
        #expect(frames.contains { $0.debugName == "editor-view-switch" })
        #expect(!frames.contains { $0.debugName == "editor-agent-view" })
        try WorkbenchUITestSupport.activate("editor-view-studio.ai.assistant", in: graph.tree.root, registry: interactions)
        settle()
        let agentFrames = graph.layoutSnapshot()
        #expect(agentFrames.contains { $0.debugName == "plugin-surface-assistant" })
        #expect(!agentFrames.contains { $0.debugName == "editor-workspace" })
        #expect(!agentFrames.contains { $0.debugName == "editor-status-bar" || $0.debugName == "editor-playback-toolbar" })
        let leading = try #require(agentFrames.first { $0.debugName == "plugin-region-leading" })
        #expect(leading.absoluteFrame.width == 280)
        #expect(leading.absoluteFrame.minY == 40 && leading.absoluteFrame.maxY == 800)
        #expect(!agentFrames.contains { $0.debugName == "plugin-region-trailing" })
        try WorkbenchUITestSupport.activate("editor-toggle-leading", in: graph.tree.root, registry: interactions)
        settle()
        #expect(!graph.layoutSnapshot().contains { $0.debugName == "plugin-region-leading" })
        try WorkbenchUITestSupport.activate("editor-toggle-leading", in: graph.tree.root, registry: interactions)
        try WorkbenchUITestSupport.activate("editor-toggle-trailing", in: graph.tree.root, registry: interactions)
        settle()
        let expanded = graph.layoutSnapshot()
        let trailing = try #require(expanded.first { $0.debugName == "plugin-region-trailing" })
        let main = try #require(expanded.first { $0.debugName == "plugin-main" })
        #expect(trailing.absoluteFrame.width == 320 && trailing.absoluteFrame.maxY == 800)
        #expect(main.absoluteFrame.maxX <= trailing.absoluteFrame.minX)
        #expect(main.absoluteFrame.width >= 640)
        try WorkbenchUITestSupport.activate("editor-toggle-trailing", in: graph.tree.root, registry: interactions)
        settle()
        try WorkbenchUITestSupport.activate("editor-view-make", in: graph.tree.root, registry: interactions)
        EditorCommandDispatcher.handle(.showContent(.files), app: app, controller: controller,
                                       registry: registry, fromCommandPalette: true)
        settle()
        #expect(app.store.content == .files)
        defer { EditorAssistantSurface.of(app).showCanvas(.follow) }
        #expect(graph.layoutSnapshot().contains { $0.debugName == "editor-workspace" })
        #expect(controller.document.group("center")?.activePanelID == "documents")
        #expect(controller.document.groups["trailing"]?.panels == ["details"])
        EditorCommandDispatcher.handle(.showPanel("inspector"), app: app, controller: controller,
                                       registry: registry, fromCommandPalette: true)
        settle()
        #expect(controller.document.groups["trailing"]?.activePanelID == "details")
        #expect(app.store.selectedEntityIDs == selected)
        #expect(app.store.state.document.identity == identity)
        #expect(app.scene.revision == revision)
    } }

    @Test("Title controls stay inside narrow and wide windows with either menu presentation",
          arguments: [Float(390), Float(720), Float(1280), Float(1440), Float(1600)], [EditorMenuPresentation.native, .titleBar])
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
        for name in ["editor-title-menu", "editor-project", "editor-playback-toolbar"] {
            if let frame = frames.first(where: { $0.debugName == name })?.absoluteFrame {
                #expect(frame.minX >= 0 && frame.maxX <= CGFloat(width) + 1, "\(name) overflow at \(width)")
                #expect(frame.minY >= 0 && frame.maxY <= 40)
            }
        }
        // Include the custom window buttons on platforms that draw them in the title bar.
        // The complete trailing cluster must reach the window edge.
        let trailing = frames.filter { ["editor-toggle-trailing", "window-control-close"].contains($0.debugName) }
            .map(\.absoluteFrame.maxX).max() ?? 0
        #expect(trailing >= CGFloat(width) - 12, "trailing controls end at \(trailing) in \(width)")
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

    @Test("The rail picks the sidebar view and folds the sidebar on a second click")
    func railFollowsLayout() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path)
        defer { app.shutdown() }
        try Self.enableAgent(in: app)
        let registry = EditorRootViewFactory.makeRegistry(app: app)
        let controller = WorkspaceController(document: EditorWorkspaceDefaults.makeDocument(registry: registry))
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: EditorActivityRail(app: app, controller: controller, onCommand: { command in
            EditorCommandDispatcher.handle(command, app: app, controller: controller, registry: registry,
                                           fromCommandPalette: true)
        }))
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
        let entries = rail()
        #expect(entries["editor-rail-hierarchy"] == true)
        #expect(entries["editor-rail-files"] == false)
        // Properties, output and the assistant have their own places; the rail only switches the sidebar.
        for absent in ["inspector", "console", "terminal", "journal", "intent-input"] {
            #expect(entries["editor-rail-" + absent] == nil, "\(absent) is on the rail")
        }
        func handle(_ command: EditorCommand) {
            EditorCommandDispatcher.handle(command, app: app, controller: controller, registry: registry,
                                           fromCommandPalette: true)
        }
        handle(.togglePanel("files"))
        #expect(EditorSidebar.of(controller).selection == "files")
        #expect(rail()["editor-rail-files"] == true)
        handle(.togglePanel("files"))
        #expect(controller.document.groups["leading"]?.isCollapsed == true)
        #expect(rail()["editor-rail-files"] == false)
        EditorRootViewFactory.activatePanel("assets", in: controller)
        #expect(controller.document.groups["leading"]?.isCollapsed == false)
        #expect(rail()["editor-rail-assets"] == true)
    } }

    @Test("Scoped palette opens with its prefix, and closing removes the card and its modal scope")
    func paletteScopeAndClose() throws { try WorkbenchUITestSupport.withEnvironment { _, focus in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path)
        defer { app.shutdown() }
        let registry = EditorRootViewFactory.makeRegistry(app: app)
        let controller = WorkspaceController(document: EditorWorkspaceDefaults.makeDocument(registry: registry))
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

    @Test("The assistant draft survives the thread unmounting and a failed submission")
    func agentDraftRetention() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path)
        defer { app.shutdown() }
        let draft = EditorAssistantSurface.of(app)
        draft.draft = "Keep this thought"
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: AssistantThread(app: app))
        graph.computeLayout(width: 324, height: 720)
        graph.install(root: Text("Properties"))
        graph.install(root: AssistantThread(app: app, inset: 200))
        graph.computeLayout(width: 324, height: 720)
        #expect(draft.draft.stringValue == "Keep this thought")
        #expect(!app.submitNaturalLanguageIntent(draft.draft.stringValue))
        #expect(draft.draft.stringValue == "Keep this thought")
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
        let draft = EditorAssistantSurface.of(app)
        draft.draft = "Next thought"
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: AssistantThread(app: app, inset: 200))
        graph.computeLayout(width: 324, height: 720)
        #expect(graph.layoutSnapshot().contains { $0.debugName == "editor-agent-review" })
        try WorkbenchUITestSupport.activate("editor-agent-discard-review", in: graph.tree.root, registry: interactions)
        for _ in 0..<3 { graph.recomposer.commitAll() }
        #expect(app.store.pendingConfirmationRequest == nil)
        #expect(app.scene.entitySummary(id: entityID) != nil)
        #expect(draft.draft.stringValue == "Next thought")
        #expect(!graph.layoutSnapshot().contains { $0.debugName == "editor-agent-review" })
    } }
}
