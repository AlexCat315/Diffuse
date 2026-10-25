import PluginRuntime
@testable import EditorUI
@testable import EditorCore
import Foundation
import GuavaUI
import GuavaUICompose
import GuavaUIRuntime
import Testing

@Suite("Settings workspace", .serialized)
@MainActor
struct SettingsWorkflowTests {
    private final class ResizingPreferences: View {
        let app: EditorApplication
        let session: EditorSettingsSession
        @State var width: Float = 1040
        init(app: EditorApplication, session: EditorSettingsSession) { self.app = app; self.session = session }
        var body: some View { SettingsPanel(app: app, session: session).frame(width: width, height: 740) }
    }
    private func withApp(_ work: (EditorApplication, InteractionRegistry) throws -> Void) throws {
        try WorkbenchUITestSupport.withEnvironment { interactions, _ in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-test-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let key = "GUAVA_EDITOR_STATE_DIRECTORY"
            let previous = ProcessInfo.processInfo.environment[key]
            #expect(WorkbenchUITestSupport.setEnvironmentValue(directory.path, for: key))
            defer {
                _ = WorkbenchUITestSupport.setEnvironmentValue(previous, for: key)
                try? FileManager.default.removeItem(at: directory)
            }
            let providerPlugin = try #require(BundledPlugins.plugin(id: "studio.ai"))
            let providers = try PluginPackageLoader().load(at: providerPlugin.package)
            let app = try EditorApplication(projectDirectory: directory.path)
            app.pluginSession.providers = AIProviderCatalog(packages: [providers])
            app.pluginSession.agents = AgentCatalog(packages: [providers])
            app.pluginSession.workbench.replace(WorkbenchCatalog(packages: [providers]))
            defer { app.shutdown() }
            try work(app, interactions)
        }
    }

    @Test("Search covers every category and supports Chinese, English and combined terms")
    func search() {
        #expect(SettingsSectionID.visible(category: .general, query: "密钥") == [.provider])
        #expect(SettingsSectionID.visible(category: .editor, query: "openai model") == [.provider])
        #expect(SettingsSectionID.visible(category: .harness, query: "vsync") == [.display])
        #expect(SettingsSectionID.visible(category: .general, query: " ") == [.appearance, .language])
        #expect(SettingsSectionID.visible(category: .general, query: "no-such-preference").isEmpty)
        #expect(Set(SettingsSectionID.allCases.map(\.category)) == Set(SettingsCategory.allCases))
    }

    @Test("Plugin categories filter actual contributions without hiding mixed packages")
    func pluginCategories() throws {
        try withApp { app, _ in
            for category in [""] + PluginCategory.allCases.map(\.rawValue) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: PluginSettings(app: app, category: category))
                for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 720, height: 1200) }
                let rows = Set(graph.layoutSnapshot().compactMap(\.debugName).filter { $0.hasPrefix("settings-plugin-row-") })
                let expected = Set(app.bundledPlugins.filter { category.isEmpty || $0.categories.contains { $0.rawValue == category } }
                    .map { "settings-plugin-row-" + $0.id })
                #expect(rows == expected)
                #expect(graph.layoutSnapshot().contains { $0.debugName == "settings-plugin-category" })
            }
        }
    }

    @Test("Settings navigation, inputs and actions remain inside narrow and desktop windows",
          arguments: [Float(390), Float(720), Float(1040)], SettingsCategory.allCases)
    func layout(width: Float, category: SettingsCategory) throws {
        try withApp { app, _ in
            let session = EditorSettingsSession(settings: app.store.aiSettings)
            session.navigation.category = category
            if category == .harness { session.harness.draft.select(AIProviderCatalog.bundled.provider(id: "openai"), in: .bundled) }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: SettingsPanel(app: app, session: session).theme(EditorVisualTheme.make(dark: true)))
            for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 740) }
            let frames = graph.layoutSnapshot()
            let search = try #require(frames.first { $0.debugName == "settings-search" })
            #expect(search.absoluteFrame.width >= 150)
            let footer = try #require(frames.first { $0.debugName == "settings-footer" })
            #expect(footer.absoluteFrame.maxY <= 740)
            for item in frames where item.debugName?.hasPrefix("settings-") == true {
                #expect(item.absoluteFrame.minX >= -1, "\(item.debugName ?? "") overflows at \(width)")
                #expect(item.absoluteFrame.maxX <= CGFloat(width) + 1, "\(item.debugName ?? "") overflows at \(width)")
            }
            #expect(frames.contains { $0.debugName == "settings-sidebar" } == (width >= 760))
        }
    }

    @Test("Provider edits stay local, validate before apply, reset, and never cross provider credentials")
    func agentEditing() throws {
        try withApp { app, _ in
            let session = EditorSettingsSession(settings: app.store.aiSettings)
            let editor = HarnessSettingsEditor(app: app, state: Binding(get: { session.harness }, set: { session.harness = $0 }), onChange: {})
            editor.select(AIProviderCatalog.bundled.provider(id: "openai"))
            editor.update { $0.draft.credentials["api-key"] = "uncommitted-test-secret"; $0.draft.model = "" }
            #expect(app.store.aiSettings.providerID.isEmpty)
            editor.apply()
            #expect(session.harness.feedback?.isError == true)
            #expect(app.store.aiSettings.providerID.isEmpty)
            editor.select(AIProviderCatalog.bundled.provider(id: "deepseek"))
            #expect(session.harness.draft.credentials.isEmpty)
            #expect(editor.isDirty)
            editor.reset()
            #expect(!editor.isDirty)
            #expect(session.harness.feedback == nil)
        }
    }

    @Test("Resizing providers preserves the editable field and does not introduce a nested scroll region")
    func providerResize() throws {
        try withApp { app, _ in
            let session = EditorSettingsSession(settings: app.store.aiSettings)
            session.navigation.category = .harness
            session.harness.draft.select(AIProviderCatalog.bundled.provider(id: "openai"), in: .bundled)
            session.harness.draft.model = "retained-model"
            let harness = ResizingPreferences(app: app, session: session)
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: harness)
            var originalField: Node?
            for width: Float in [1040, 390, 720, 1040] {
                harness.width = width
                for _ in 0..<6 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 740) }
                let section = try WorkbenchUITestSupport.named("settings-section-provider", in: graph.tree.root)
                #expect(WorkbenchUITestSupport.firstNode(section) { $0.accessibility?.role == .scrollArea } == nil)
                let field = try #require(WorkbenchUITestSupport.firstNode(section) {
                    $0.accessibility?.role == .textField && $0.accessibility?.label == EditorUI.L("Model")
                })
                if let originalField { #expect(field === originalField) } else { originalField = field }
                #expect(session.harness.draft.model.stringValue == "retained-model")
            }
        }
    }

    @Test("Harness settings adapt to touch, mixed input, RTL and large text", arguments: [Float(390), 720, 1280])
    func adaptiveHarness(width: Float) throws {
        try withApp { app, _ in
            let session = EditorSettingsSession(settings: app.store.aiSettings)
            session.navigation.category = .harness
            session.harness.draft.select(AIProviderCatalog.bundled.provider(id: "openai"), in: .bundled)
            var surface = UIEnvironment()
            surface.viewport.width = width
            surface.input = width == 390 ? [.touch] : width == 720 ? [.pointer, .touch, .keyboard] : [.pointer, .keyboard]
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: SettingsPanel(app: app, session: session)
                .surfaceEnvironment(surface).textScaler(.init(width == 720 ? 1 : 2))
                .layoutDirection(width == 1280 ? .rtl : .ltr)
                .theme(EditorVisualTheme.make(dark: width != 390)))
            for _ in 0..<6 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 740) }
            let frames = graph.layoutSnapshot()
            let footer = try #require(frames.first { $0.debugName == "settings-footer" })
            #expect(footer.absoluteFrame.maxY <= 740)
            for item in frames where item.debugName?.hasPrefix("settings-") == true {
                #expect(item.absoluteFrame.minX >= -1)
                #expect(item.absoluteFrame.maxX <= CGFloat(width) + 1, "\(item.debugName ?? "") at \(width)")
            }
        }
    }

    @Test("Navigation and presentation remounts preserve the Harness draft and search state")
    func retainedSession() throws {
        try withApp { app, interactions in
            let session = EditorSettingsSession(settings: app.store.aiSettings)
            session.navigation.category = .harness
            session.harness.draft.select(AIProviderCatalog.bundled.provider(id: "openai"), in: .bundled)
            session.harness.draft.model = "my-model"
            session.harness.draft.credentials["api-key"] = "uncommitted-test-secret"
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            func settle() {
                for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 1040, height: 740) }
            }
            graph.install(root: SettingsPanel(app: app, session: session)); settle()
            try WorkbenchUITestSupport.activate("settings-category-general", in: graph.tree.root, registry: interactions); settle()
            #expect(session.navigation.category == .general)
            #expect(session.harness.draft.model.stringValue == "my-model")
            graph.install(root: EmptyView())
            session.navigation.query = "模型"
            graph.install(root: SettingsPanel(app: app, session: session).theme(EditorVisualTheme.make(dark: false))); settle()
            #expect(graph.layoutSnapshot().contains { $0.debugName == "settings-harness-model" })
            #expect(session.harness.draft.credentials["api-key"]?.stringValue == "uncommitted-test-secret")
            #expect(session.navigation.query.stringValue == "模型")
        }
    }

    @Test("The search shortcut moves focus from a settings action to the global search field")
    func keyboardSearch() throws {
        try withApp { app, interactions in
            let session = EditorSettingsSession(settings: app.store.aiSettings)
            session.navigation.category = .harness
            session.harness.draft.select(AIProviderCatalog.bundled.provider(id: "openai"), in: .bundled)
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: SettingsPanel(app: app, session: session))
            func settle() { for _ in 0..<5 { graph.recomposer.commitAll(); graph.computeLayout(width: 1040, height: 740) } }
            settle()
            let focus = try #require(FocusChainHolder.current)
            let action = try WorkbenchUITestSupport.named("settings-harness-reset", in: graph.tree.root)
            focus.focus(try #require(WorkbenchUITestSupport.firstNode(action) { $0.isFocusable }))
            let input = EventDispatcher(tree: graph.tree, interactions: interactions, capture: PointerCapture(), focusChain: focus)
            input.dispatch(.keyDown(.init(scancode: Scancode.f, keycode: 0, modifiers: .lgui, isRepeat: false)))
            settle()
            input.dispatch(.textInput("vsync")); settle()
            #expect(session.navigation.query.stringValue == "vsync")
            #expect(graph.layoutSnapshot().contains { $0.debugName == "settings-vsync" })
        }
    }
}

@Suite("Agent surface ownership", .serialized)
@MainActor
struct AgentSurfaceTests {
    private func withApp(_ work: (EditorApplication) throws -> Void) throws {
        try WorkbenchUITestSupport.withEnvironment { _, _ in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-surface-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let key = "GUAVA_EDITOR_STATE_DIRECTORY"
            let previous = ProcessInfo.processInfo.environment[key]
            #expect(WorkbenchUITestSupport.setEnvironmentValue(directory.path, for: key))
            defer {
                _ = WorkbenchUITestSupport.setEnvironmentValue(previous, for: key)
                try? FileManager.default.removeItem(at: directory)
            }
            let app = try EditorApplication(projectDirectory: directory.path)
            defer { app.shutdown() }
            try work(app)
        }
    }

    @Test("Disabling the agent package removes the assistant panel from the workbench")
    func agentPanelFollowsPackageState() throws {
        try withApp { app in
            let plugin = try #require(BundledPlugins.plugin(id: "studio.ai"))
            let package = try PluginPackageLoader().load(at: plugin.package)
            app.pluginSession.agents = AgentCatalog(packages: [package])
            app.pluginSession.workbench.replace(WorkbenchCatalog(packages: [package]))
            #expect(app.isAgentEnabled)

            let enabled = EditorRootViewFactory.makeRegistry(app: app)
            #expect(enabled.descriptor(for: "intent-input") != nil)

            app.pluginSession.agents = .empty
            let disabled = EditorRootViewFactory.makeRegistry(app: app)
            #expect(disabled.descriptor(for: "intent-input") == nil)
            #expect(!app.isAgentEnabled)
            #expect(!app.isAIAvailable)
        }
    }

    @Test("Without an agent package the Harness settings section is not offered")
    func harnessSettingsHideWithoutAgent() {
        let hidden = SettingsSectionID.visible(category: .harness, query: "", agentEnabled: false)
        #expect(hidden.isEmpty)
        #expect(SettingsSectionID.visible(category: .harness, query: "", agentEnabled: true) == [.provider, .execution, .capabilities])
        #expect(SettingsSectionID.visible(category: .general, query: "harness", agentEnabled: false).isEmpty)
    }
}
