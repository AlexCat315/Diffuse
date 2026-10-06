@testable import EditorApp
import EditorCore
import EngineKernel
import Foundation
import GuavaUIApp
import GuavaUICompose
import GuavaUIWorkspace
import RenderBackend
import Testing

@Suite("EditorProductivityWorkflow", .serialized)
struct EditorProductivityWorkflowTests {
    private func document() -> WorkspaceDocument {
        WorkspaceDocument(
            panels: ["viewport": WorkspacePanel(id: "viewport", title: "Viewport"),
                     "scripts": WorkspacePanel(id: "scripts", title: "Scripts")],
            groups: ["center": WorkspaceTabGroup(id: "center", panels: ["viewport", "scripts"], activePanelID: "viewport")],
            slots: WorkspaceSlot.standardEditorSlots(center: .group("center")), layoutTree: .group("center"))
    }

    @Test("maximizing and restoring preserve docking and do not persist a temporary layout")
    func maximizeRestore() {
        let original = document()
        let controller = WorkspaceController(document: original)
        let result = controller.dispatch(.toggleMaximize("scripts"))
        #expect(result.didChange)
        #expect(!result.persistenceDirty)
        #expect(controller.maximizedPanelID == "scripts")
        #expect(controller.document == original)
        _ = controller.dispatch(.restoreMaximized)
        #expect(controller.maximizedPanelID == nil)
        #expect(controller.document == original)
        _ = controller.dispatch(.toggleMaximize("scripts"))
        _ = controller.dispatch(.closePanel("scripts"))
        #expect(controller.maximizedPanelID == nil)
        _ = controller.dispatch(.reopenPanel("scripts"))
        #expect(controller.document.groupContaining(panelID: "scripts") != nil)
    }

    @Test("commands are searchable by localized words, multiple tokens and abbreviations")
    func localSearch() throws {
        #expect(EditorCommandSearch.score("保存 场景", in: "Save Scene 保存场景 scene.save") != nil)
        #expect(EditorCommandSearch.score("savs", in: "Save Scene") != nil)
        #expect(EditorCommandSearch.score("build texture", in: "Build Project") == nil)
        let exact = try #require(EditorCommandSearch.score("Build", in: "Build"))
        let partial = try #require(EditorCommandSearch.score("Build", in: "Build Project"))
        #expect(exact > partial)
    }

    @Test("script and film workspaces have distinct defaults")
    func workspaceDefaults() {
        let ids: [PanelID] = ["viewport", "scripts", "hierarchy", "inspector", "assets", "console", "render-pipeline", "animation", "developer-tools", "intent-input", "confirmation-host"]
        let registry = PanelRegistry(ids.map { id in PanelDescriptor(id: id, title: id.rawValue) { EmptyView() } })
        let level = EditorWorkspaceDefaults.makeDocument(mode: .level, preset: .levelDefault, registry: registry)
        let script = EditorWorkspaceDefaults.makeDocument(mode: .scripting, preset: .scriptingDefault, registry: registry)
        let film = EditorWorkspaceDefaults.makeDocument(mode: .animation, preset: .animationDefault, registry: registry)
        #expect(level.group("center")?.activePanelID == "viewport")
        #expect(script.group("center")?.activePanelID == "scripts")
        #expect(WorkspaceController(document: script).focusedPanelID == "scripts")
        #expect(script.group("bottom")?.activePanelID == "console")
        #expect(film.group("bottom")?.activePanelID == "animation")
        #expect(EditorWorkspaceMode.scripting.isGameWorkspace)
        #expect(!EditorWorkspaceMode.animation.isGameWorkspace)
    }

    @Test("game preview fits wide and portrait resolutions without stretching")
    func previewAspect() {
        let frame = ViewportScreenFrame(x: 20, y: 10, width: 1000, height: 600)
        let wide = ViewportPresentationGeometry.fit(frame, aspectRatio: 16 / 9)
        #expect(abs(wide.width / wide.height - 16 / 9) < 0.001)
        #expect(wide.x + wide.width / 2 == frame.x + frame.width / 2)
        #expect(wide.y + wide.height / 2 == frame.y + frame.height / 2)
        let portrait = ViewportPresentationGeometry.fit(frame, aspectRatio: 9 / 16)
        #expect(abs(portrait.width / portrait.height - 9 / 16) < 0.001)
        #expect(portrait.height == frame.height)
        #expect(portrait.width < frame.width)
        #expect(ViewportPresentationGeometry.fit(frame, aspectRatio: nil) == frame)
    }

    @Test("game pointer input maps the displayed image to the selected resolution")
    func gamePointerCoordinates() {
        let frame = ViewportScreenFrame(x: 100, y: 80, width: 640, height: 360)
        let click = InputEvent.mouseButtonDown(.init(button: .left, x: 420, y: 260, clicks: 1))
        let mapped = EditorGamePreviewInput.map(click, frame: frame, resolution: .init(width: 1280, height: 720))
        guard case .mouseButtonDown(let pointer) = mapped else { Issue.record("Expected pointer event"); return }
        #expect(pointer.x == 640 && pointer.y == 360)
        let motion = EditorGamePreviewInput.map(.mouseMotion(.init(x: 420, y: 260, deltaX: 4, deltaY: -2)),
                                                frame: frame, resolution: .init(width: 1280, height: 720))
        guard case .mouseMotion(let moved) = motion else { Issue.record("Expected motion event"); return }
        #expect(moved.deltaX == 8 && moved.deltaY == -4)
    }

    @Test("local commands work with no AI provider and reveal a collapsed panel during navigation")
    func commandsWithoutAI() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("guava-local-commands-\(UUID())")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let app = try EditorApplication(projectDirectory: project.path, seedPreviewScene: false)
        defer { app.shutdown() }
        var settings = app.store.aiSettings
        settings.provider = .none
        app.store.dispatch(.setAISettings(settings))
        #expect(!app.isAIAvailable)
        #expect(EditorCommandSearch.commands(app: app).contains { $0.id == "scene.settings" && $0.enabled })
        var layout = document()
        layout.panels["inspector"] = WorkspacePanel(id: "inspector", title: "Inspector")
        layout.groups["trailing"] = WorkspaceTabGroup(id: "trailing", panels: ["inspector"], activePanelID: "inspector", isCollapsed: true)
        layout.slots[.trailing]?.layout = .group("trailing")
        let controller = WorkspaceController(document: layout)
        let registry = PanelRegistry([])
        _ = controller.dispatch(.toggleMaximize("viewport"))
        EditorCommandDispatcher.handle(.showSceneSettings, app: app, controller: controller,
                                       registry: registry, fromCommandPalette: true)
        #expect(app.store.inspectorSceneSettingsVisible)
        #expect(controller.maximizedPanelID == nil)
        #expect(controller.document.group("trailing")?.isCollapsed == false)
        #expect(controller.focusedPanelID == "inspector")
        EditorCommandDispatcher.handle(.showProblems, app: app, controller: controller,
                                       registry: registry, fromCommandPalette: true)
        #expect(app.store.outputTab == .problems)
    }
}
