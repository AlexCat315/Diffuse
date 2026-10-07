@testable import EditorApp
import EditorCore
import Foundation
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace
import Testing

@Suite("Workspace preset regression", .serialized)
struct WorkspacePresetRegressionTests {
    @Test("the workspace and layout labels are translated by the app resource bundle")
    func localizedMenus() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let previous = EditorLocalizationPreferences.language
        EditorLocalizationPreferences.language = .simplifiedChinese
        defer { EditorLocalizationPreferences.language = previous }
        let model = EditorMenuModel.make(workspaceMode: .level, activeLayoutPreset: .levelDefault, playbackState: .stopped)
        #expect(model.menus.contains { $0.title == "工作区" })
        #expect(model.menus.contains { $0.title == "布局" })
        #expect(L(EditorLayoutPreset.levelWorkbench.title) == "场景与脚本")
        #expect(L(EditorLayoutPreset.modelingSculpt.title) == "视口优先")
        #expect(L(EditorLayoutPreset.animationSequencer.title) == "动画属性")
    } }

    private func registry() -> PanelRegistry {
        let ids: [PanelID] = ["viewport", "scripts", "hierarchy", "inspector", "assets", "console",
                              "animation", "render-pipeline", "developer-tools", "intent-input", "confirmation-host"]
        return PanelRegistry(ids.map { id in
            let slot: WorkspaceSlotID
            switch id.rawValue {
            case "viewport", "scripts": slot = .center
            case "hierarchy": slot = .leading
            case "inspector", "intent-input": slot = .trailing
            default: slot = .bottom
            }
            return PanelDescriptor(id: id, title: id.rawValue, preferredSlot: slot) {
                Text(id.rawValue).flex().debugName("preset-" + id.rawValue)
            }
        })
    }

    @Test("every preset renders its named tools with usable frames and distinct visible panel sets")
    func presetFrames() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let registry = registry()
        let expected: [(EditorLayoutPreset, Set<String>)] = [
            (.levelDefault, ["viewport", "hierarchy", "inspector"]),
            (.levelWorkbench, ["viewport", "scripts", "hierarchy", "inspector", "developer-tools"]),
            (.levelCinematics, ["viewport", "hierarchy", "inspector", "animation", "render-pipeline"]),
            (.scriptingDefault, ["scripts", "assets", "inspector", "console"]),
            (.modelingDefault, ["viewport", "assets", "inspector"]),
            (.modelingSculpt, ["viewport"]),
            (.animationDefault, ["viewport", "hierarchy", "inspector", "animation"]),
            (.animationSequencer, ["viewport", "hierarchy", "animation", "assets"]),
        ]
        for (preset, visible) in expected {
            let document = EditorWorkspaceDefaults.makeDocument(mode: preset.mode, preset: preset, registry: registry)
            #expect(document.hasValidLayoutReferences)
            let assigned = document.groups.values.flatMap(\.panels)
            let allowed = Set(registry.ids.filter { preset.mode.profile.allowsPanel($0.rawValue) })
            #expect(assigned.count == allowed.count)
            #expect(Set(assigned) == allowed)
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: WorkspaceView(controller: WorkspaceController(document: document)) { registry.make($0) })
            graph.computeLayout(width: 1280, height: 720)
            let frames = graph.layoutSnapshot().filter { $0.debugName?.hasPrefix("preset-") == true }
            #expect(Set(frames.compactMap { $0.debugName?.replacingOccurrences(of: "preset-", with: "") }) == visible)
            for frame in frames {
                #expect(frame.absoluteFrame.width >= 140, "\(preset): \(frame.debugName ?? "") is too narrow")
                #expect(frame.absoluteFrame.height >= 100, "\(preset): \(frame.debugName ?? "") is too short")
                if frame.debugName == "preset-inspector" {
                    #expect(frame.absoluteFrame.width >= 220, "Inspector controls need room for labeled fields")
                }
                if frame.debugName == "preset-assets" {
                    #expect(frame.absoluteFrame.height >= 180, "Asset grid needs room below its toolbar")
                }
            }
        }
    } }

    @Test("selecting an existing or saved preset applies the template, while mode switching preserves custom docking")
    func presetSelection() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guava-preset-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "GUAVA_EDITOR_STATE_DIRECTORY"
        let previous = ProcessInfo.processInfo.environment[key]
        #expect(WorkbenchUITestSupport.setEnvironmentValue(directory.appendingPathComponent("state").path, for: key))
        defer { _ = WorkbenchUITestSupport.setEnvironmentValue(previous, for: key) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: false)
        defer { app.shutdown() }
        let registry = registry()
        app.store.dispatch(.setWorkspaceMode(.level))
        app.store.dispatch(.setActiveLayoutPreset(.levelDefault))
        let standard = EditorWorkspaceDefaults.makeDocument(mode: .level, preset: .levelDefault, registry: registry)
        let controller = WorkspaceController(document: standard)
        _ = controller.dispatch(.collapse("trailing"))
        let custom = controller.document
        EditorCommandDispatcher.handle(.saveLayout, app: app, controller: controller, registry: registry, fromCommandPalette: true)
        EditorCommandDispatcher.handle(.setWorkspaceMode(.scripting), app: app, controller: controller, registry: registry, fromCommandPalette: true)
        EditorCommandDispatcher.handle(.setWorkspaceMode(.level), app: app, controller: controller, registry: registry, fromCommandPalette: true)
        #expect(controller.document == custom)
        EditorCommandDispatcher.handle(.setLayoutPreset(.levelDefault), app: app, controller: controller, registry: registry, fromCommandPalette: true)
        #expect(controller.document == standard)
        EditorRootViewFactory.saveWorkspaceLayout(WorkspaceController(document: custom), for: .level, preset: .levelCinematics)
        EditorCommandDispatcher.handle(.setLayoutPreset(.levelCinematics), app: app, controller: controller, registry: registry, fromCommandPalette: true)
        #expect(controller.document == EditorWorkspaceDefaults.makeDocument(mode: .level, preset: .levelCinematics, registry: registry))
        #expect(app.store.activeLayoutPreset == .levelCinematics)
        let commands = EditorCommandSearch.commands(app: app)
        #expect(commands.contains { $0.id == "layout.levelCinematics" })
        #expect(!commands.contains { $0.id == "layout.modelingSculpt" })
    } }

    @Test("Window reveals closed and collapsed panels, Inspector exits scene settings, and Restore Panels expands docks")
    func panelCommands() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guava-panel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: false)
        defer { app.shutdown() }
        let registry = registry()
        let controller = WorkspaceController(document: EditorWorkspaceDefaults.makeDocument(mode: .modeling, preset: .modelingSculpt, registry: registry))
        _ = controller.dispatch(.closePanel("inspector"))
        _ = controller.dispatch(.toggleMaximize("viewport"))
        app.store.dispatch(.setInspectorSceneSettingsVisible(true))
        EditorCommandDispatcher.handle(.showPanel("inspector"), app: app, controller: controller, registry: registry, fromCommandPalette: true)
        #expect(!app.store.inspectorSceneSettingsVisible)
        #expect(controller.maximizedPanelID == nil)
        #expect(controller.focusedPanelID == "inspector")
        #expect(controller.document.groupContaining(panelID: "inspector")?.isCollapsed == false)
        EditorCommandDispatcher.handle(.restorePanels, app: app, controller: controller, registry: registry, fromCommandPalette: true)
        #expect(!controller.document.groups.values.contains { $0.isCollapsed })
    } }
}
