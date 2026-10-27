@testable import EditorUI
import EditorCore
import Foundation
import CoveUI
import CoveUICompose
import CoveUIRuntime
import CoveUIWorkspace
import Testing

@Suite("Workspace layout regression", .serialized)
@MainActor
struct WorkspacePresetRegressionTests {
    @Test("the content and layout labels are translated by the app resource bundle")
    func localizedMenus() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let previous = EditorLocalizationPreferences.language
        EditorLocalizationPreferences.language = .simplifiedChinese
        defer { EditorLocalizationPreferences.language = previous }
        let catalog = EditorCommandCatalog.make(EditorCommandContext(content: .scene))
        // No app, so no agent plugin: the agent menu is absent rather than empty.
        #expect(catalog.menus.map(\.title) == ["文件", "编辑", "选择", "世界", "视图", "运行", "窗口", "帮助"])
        #expect(!catalog.menus.contains { $0.id == "agent" })
        let view = try #require(catalog.menus.first { $0.id == "view" })
        let nested = view.items.compactMap { item -> String? in
            if case let .submenu(menu) = item { return menu.title }
            return nil
        }
        #expect(nested == ["布局", "面板"])
        #expect(catalog.entries.first { $0.id == "content.timeline" }?.title == "时间线")
    } }

    private func registry() -> WorkspacePanelRegistry {
        let ids: [WorkspacePanelID] = ["viewport", "documents", "sidebar", "hierarchy", "inspector", "assets", "console",
                              "animation", "render-pipeline", "developer-tools", "intent-input"]
        return WorkspacePanelRegistry(ids.map { id in
            let slot: WorkspaceSlotID
            switch id.rawValue {
            case "viewport", "documents": slot = .center
            case "sidebar", "hierarchy", "assets": slot = .leading
            case "inspector", "intent-input": slot = .trailing
            default: slot = .bottom
            }
            return WorkspacePanelDescriptor(id: id, title: id.rawValue, defaultSlot: slot, configure: { $0.isCollapsible = slot != .center }) {
                Text(id.rawValue).flex().debugName("preset-" + id.rawValue)
            }
        })
    }

    @Test("the default layout places every tool and renders the front ones with usable frames")
    func presetFrames() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let registry = registry()
        do {
            let preset = "default"
            let visible: Set<String> = ["viewport", "sidebar", "inspector", "console"]
            let document = EditorWorkspaceDefaults.makeDocument(registry: registry)
            #expect(document.hasValidLayoutReferences)
            // Sidebar views show through the sidebar pane instead of docking.
            // The center holds only the scene; code and timeline wait until picked.
            let docked = registry.descriptors.filter { !EditorSidebar.isView($0) && $0.panel.id != "documents" }.map(\.panel.id)
            let assigned = document.groups.values.flatMap(\.panels)
            #expect(assigned.count == docked.count)
            #expect(Set(assigned) == Set(docked))
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

    @Test("a saved layout survives content switches, and Reset Layout restores the default")
    func presetSelection() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cove-preset-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "COVE_EDITOR_STATE_DIRECTORY"
        let previous = ProcessInfo.processInfo.environment[key]
        #expect(WorkbenchUITestSupport.setEnvironmentValue(directory.appendingPathComponent("state").path, for: key))
        defer { _ = WorkbenchUITestSupport.setEnvironmentValue(previous, for: key) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: false)
        defer { app.shutdown() }
        let registry = registry()
        let standard = EditorWorkspaceDefaults.makeDocument(registry: registry)
        let controller = WorkspaceController(document: standard)
        _ = controller.dispatch(.collapse("trailing"))
        EditorCommandDispatcher.handle(.saveLayout, app: app, controller: controller, registry: registry, fromCommandPalette: true)
        EditorCommandDispatcher.handle(.showContent(.files), app: app, controller: controller, registry: registry, fromCommandPalette: true)
        #expect(app.store.content == .files)
        #expect(controller.document.group("center")?.activePanelID == "documents")
        #expect(controller.document.groups["trailing"]?.isCollapsed == true)
        EditorCommandDispatcher.handle(.showContent(.scene), app: app, controller: controller, registry: registry, fromCommandPalette: true)
        #expect(app.store.content == .scene)
        #expect(EditorRootViewFactory.makeController(registry: registry).document.groups["trailing"]?.isCollapsed == true)
        EditorCommandDispatcher.handle(.resetLayout, app: app, controller: controller, registry: registry, fromCommandPalette: true)
        #expect(controller.document == standard)
    } }

    @Test("Window reveals closed and collapsed panels, Inspector exits scene settings, and Restore Panels expands docks")
    func panelCommands() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cove-panel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: false)
        defer { app.shutdown() }
        let registry = registry()
        let controller = WorkspaceController(document: EditorWorkspaceDefaults.makeDocument(registry: registry))
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

    @Test("Area toggles collapse every group on an edge, then restore them; the center never collapses")
    func panelAreaToggles() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cove-area-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: false)
        defer { app.shutdown() }
        let registry = registry()
        // The bottom edge split into two groups.
        var document = EditorWorkspaceDefaults.makeDocument(registry: registry)
        document.groups["bottom"]?.panels.removeAll { $0 == "render-pipeline" }
        document.groups["render-tools"] = WorkspaceTabGroup(id: "render-tools", panels: ["render-pipeline"],
                                                            activePanelID: "render-pipeline")
        document = WorkspaceDocument(panels: document.panels, groups: document.groups,
            slots: WorkspaceSlot.standardEditorSlots(leading: .group("leading"), center: .group("center"),
                trailing: .group("trailing"),
                bottom: .split(axis: .horizontal, fraction: 0.6, first: .group("bottom"), second: .group("render-tools"))))
        let controller = WorkspaceController(document: document)
        let bottom = try #require(controller.document.slots[.bottom]?.layout?.leafGroupIDs)
        #expect(bottom.count == 2)
        func handle(_ command: EditorCommand) {
            EditorCommandDispatcher.handle(command, app: app, controller: controller, registry: registry,
                                           fromCommandPalette: true)
        }
        handle(.togglePanelArea(.bottom))
        #expect(bottom.allSatisfy { controller.document.groups[$0]?.isCollapsed == true })
        #expect(controller.document.groups["leading"]?.isCollapsed == false)
        handle(.togglePanelArea(.bottom))
        #expect(bottom.allSatisfy { controller.document.groups[$0]?.isCollapsed == false })

        // One collapsed group still counts as showing: the toggle hides the rest.
        _ = controller.dispatch(.collapse(bottom[0]))
        handle(.togglePanelArea(.bottom))
        #expect(bottom.allSatisfy { controller.document.groups[$0]?.isCollapsed == true })

        handle(.togglePanelArea(.leading))
        #expect(controller.document.groups["leading"]?.isCollapsed == true)
        #expect(controller.document.groups["center"]?.isCollapsed == false)
    } }

    @Test("A panel missing from an older saved layout opens and shows from the rail, even with its edge collapsed")
    func railOpensPanelMissingFromSavedLayout() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cove-rail-new-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: false)
        defer { app.shutdown() }
        let registry = EditorRootViewFactory.makeRegistry(app: app)
        var saved = EditorWorkspaceDefaults.makeDocument(registry: registry)
        // A layout saved before the terminal existed: no panel, no tab.
        saved.panels.removeValue(forKey: "terminal")
        for id in Array(saved.groups.keys) { saved.groups[id]?.panels.removeAll { $0 == "terminal" } }
        saved.groups["bottom"]?.activePanelID = "console"
        let controller = WorkspaceController(document: EditorRootViewFactory.reconciledWorkspaceDocument(
            saved, registry: registry))
        _ = controller.dispatch(.collapse("bottom"))
        EditorCommandDispatcher.handle(.togglePanel("terminal"), app: app, controller: controller, registry: registry,
                                       fromCommandPalette: true)
        let group = try #require(controller.document.groupContaining(panelID: "terminal"))
        #expect(group.activePanelID == "terminal")
        #expect(group.isCollapsed == false)
    } }

    @Test("Clicking the rail entry of the showing panel collapses its group; clicking again restores it")
    func railToggle() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cove-rail-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: false)
        defer { app.shutdown() }
        let registry = registry()
        let controller = WorkspaceController(document: EditorWorkspaceDefaults.makeDocument(registry: registry))
        func handle(_ command: EditorCommand) {
            EditorCommandDispatcher.handle(command, app: app, controller: controller, registry: registry,
                                           fromCommandPalette: true)
        }
        #expect(controller.document.groups["trailing"]?.activePanelID == "inspector")
        // A different panel in the same group switches tabs instead of collapsing.
        handle(.togglePanel("intent-input"))
        #expect(controller.document.groups["trailing"]?.activePanelID == "intent-input")
        #expect(controller.document.groups["trailing"]?.isCollapsed == false)
        handle(.togglePanel("intent-input"))
        #expect(controller.document.groups["trailing"]?.isCollapsed == true)
        handle(.togglePanel("intent-input"))
        #expect(controller.document.groups["trailing"]?.isCollapsed == false)
        #expect(controller.document.groups["trailing"]?.activePanelID == "intent-input")
        // The viewport cannot collapse, so its rail entry keeps it showing.
        handle(.togglePanel("viewport"))
        #expect(controller.document.groupContaining(panelID: "viewport")?.isCollapsed == false)
    } }
}
