import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RHIWGPU
import EngineKernel
import Testing
@testable import EditorApp

@Suite("Welcome project workflow", .serialized)
@MainActor
struct WelcomeWorkflowTests {
    @Test("blank and sample creation forms remain interactive through open and cancel")
    func creationForms() throws { try WorkbenchUITestSupport.withEnvironment { registry, _ in
        let context = EditorLaunchContext(backendConfig: .init(), backend: WGPUBackend(config: .init()),
                                          events: PlatformEventBridge(), shellState: nil)
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: WelcomeView(context: context).theme(EditorVisualTheme.make(dark: false)))
        graph.computeLayout(width: 1280, height: 720)
        for action in ["welcome-new-project", "welcome-example-project"] {
            try WorkbenchUITestSupport.activate(action, in: graph.tree.root, registry: registry)
            graph.recomposer.commitAll()
            graph.computeLayout(width: 1280, height: 720)
            let name = try WorkbenchUITestSupport.named("welcome-project-name", in: graph.tree.root)
            let field = try #require(WorkbenchUITestSupport.firstNode(name) { registry.handlers(for: $0).text != nil })
            #expect(registry.handlers(for: field).key != nil)
            let create = try WorkbenchUITestSupport.named("welcome-create-project", in: graph.tree.root)
            #expect(create.absoluteFrame.width > 40)
            #expect(create.absoluteFrame.minY >= 0)
            #expect(create.absoluteFrame.maxY <= 720)
            try WorkbenchUITestSupport.activate("welcome-cancel-creation", in: graph.tree.root, registry: registry)
            graph.recomposer.commitAll()
            #expect(WorkbenchUITestSupport.firstNode(graph.tree.root) {
                $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "welcome-project-name"
            } == nil)
            #expect(!context.isProjectLoaded)
        }
    } }

    @Test("launcher creates, closes and reopens blank projects on every platform")
    func blankProjectRoundTrip() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("guava-blank-round-trip-\(UUID())")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let stateKey = "GUAVA_EDITOR_STATE_DIRECTORY"
        let previousState = ProcessInfo.processInfo.environment[stateKey]
        let previousRecents = UserDefaults.standard.object(forKey: "GuavaRecentProjects")
        defer {
            #expect(WorkbenchUITestSupport.setEnvironmentValue(previousState, for: stateKey))
            if let previousRecents { UserDefaults.standard.set(previousRecents, forKey: "GuavaRecentProjects") }
            else { UserDefaults.standard.removeObject(forKey: "GuavaRecentProjects") }
            try? FileManager.default.removeItem(at: parent)
        }
        try #require(WorkbenchUITestSupport.setEnvironmentValue(parent.appendingPathComponent("editor-state").path,
                                                               for: stateKey))
        let backend = WGPUBackend(config: .init())
        let context = EditorLaunchContext(backendConfig: .init(), backend: backend,
                                          events: PlatformEventBridge(), shellState: nil)
        defer { context.shutdown(); try? backend.shutdown() }
        try context.createProject(name: "Empty", parent: parent, template: .blank)
        let app = try #require(context.bundle?.app)
        #expect(app.scene.entityCount == 0)
        #expect(app.scriptWorkspace.snapshot.documents.isEmpty)
        context.closeProject()
        #expect(!context.isProjectLoaded)
        try context.loadProject(directory: parent.appendingPathComponent("Empty").path)
        #expect(context.isProjectLoaded)
        #expect(context.bundle?.app.scene.entityCount == 0)
    }

    // ScriptBehavior libraries need the host Swift exports currently available
    // on macOS/Linux. Windows still exercises the blank-project lifecycle above.
    #if os(macOS) || os(Linux)
    @Test("launcher creates, compiles, plays, closes and reopens independent projects")
    func projectRoundTrip() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("guava-launcher-round-trip-\(UUID())")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [repo.appendingPathComponent("Editor/.build/out/Products/Debug/EditorApp"),
                          repo.appendingPathComponent("Editor/.build/debug/EditorApp")]
        let host = try #require(candidates.first { FileManager.default.fileExists(atPath: $0.path) })
        let sdk = ProjectScriptBuildConfiguration.discover(for: host.resolvingSymlinksInPath(), environment: [:])
        #expect(!sdk.engineModulePaths.isEmpty)
        let overrides = ["GUAVA_ENGINE_MODULE_PATHS": sdk.engineModulePaths.joined(separator: ","),
                         "GUAVA_ENGINE_CLANG_MODULE_MAP_PATHS": sdk.clangModuleMapPaths.joined(separator: ","),
                         "GUAVA_ENGINE_CLANG_INCLUDE_PATHS": sdk.clangIncludePaths.joined(separator: ",")]
        let previousOverrides = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, previous) in previousOverrides {
                if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
            }
        }
        let previousStateDirectory = ProcessInfo.processInfo.environment["GUAVA_EDITOR_STATE_DIRECTORY"]
        let previousRecents = UserDefaults.standard.object(forKey: "GuavaRecentProjects")
        setenv("GUAVA_EDITOR_STATE_DIRECTORY", parent.appendingPathComponent("editor-state").path, 1)
        defer {
            if let previousStateDirectory { setenv("GUAVA_EDITOR_STATE_DIRECTORY", previousStateDirectory, 1) }
            else { unsetenv("GUAVA_EDITOR_STATE_DIRECTORY") }
            if let previousRecents { UserDefaults.standard.set(previousRecents, forKey: "GuavaRecentProjects") }
            else { UserDefaults.standard.removeObject(forKey: "GuavaRecentProjects") }
            try? FileManager.default.removeItem(at: parent)
        }
        let backend = WGPUBackend(config: .init())
        let context = EditorLaunchContext(backendConfig: .init(), backend: backend,
                                          events: PlatformEventBridge(), shellState: nil)
        defer { context.shutdown(); try? backend.shutdown() }
        try context.createProject(name: "Crystal Sample", parent: parent, template: .crystalRush)
        let app = try #require(context.bundle?.app)
        for _ in 0..<400 {
            if app.scriptWorkspace.snapshot.selectedDocument?.loadedRevision != nil
                || app.scriptWorkspace.snapshot.selectedDocument?.buildState.isFailed == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let doc = try #require(app.scriptWorkspace.snapshot.selectedDocument)
        #expect(doc.loadedRevision != nil, "\(doc.output)")
        guard doc.loadedRevision != nil else { return }
        #expect(!doc.buildState.isFailed)
        #expect(app.scene.entityCount == 1)
        app.applyPlaybackState(.playing)
        app.scene.tickScene(deltaTime: 1.0 / 60, frameIndex: 1, inputEvents: [], drivesAudio: false)
        #expect(app.scene.entityCount == 60)
        app.applyPlaybackState(.stopped)
        #expect(app.scene.entityCount == 1)
        app.store.dispatch(.setThemeMode(.light))
        app.scriptWorkspace.setProjectTrusted(false)
        context.closeProject()
        #expect(!context.isProjectLoaded)
        #expect(backend.state == .deviceReady)
        try context.createProject(name: "Empty", parent: parent, template: .blank)
        let empty = try #require(context.bundle?.app)
        #expect(empty.store.state.themeMode == .light)
        #expect(empty.scene.entityCount == 0)
        #expect(empty.scriptWorkspace.snapshot.documents.isEmpty)
        context.closeProject()
        #expect(!context.isProjectLoaded)
        try context.loadProject(directory: parent.appendingPathComponent("Crystal Sample").path)
        #expect(context.bundle?.app.scene.entityCount == 1)
        #expect(context.bundle?.app.scriptWorkspace.snapshot.documents.count == 1)
    }
    #endif

}
