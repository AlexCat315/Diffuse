import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import NativeRHI
import EngineKernel
import Testing
@testable import EditorUI

private final class ProjectWorkspaceTestBundle: NSObject {}

/// Keeps the user's saved projects and editor state out of each test.
private struct IsolatedProjectState {
    let parent: URL
    private let previousState: String?
    private let previousDefaults: [String: Any?]
    private static let keys = ["GuavaOpenProjects", "GuavaActiveProject"]

    init(_ label: String) throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("guava-\(label)-\(UUID())")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        previousState = ProcessInfo.processInfo.environment["GUAVA_EDITOR_STATE_DIRECTORY"]
        previousDefaults = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        try #require(WorkbenchUITestSupport.setEnvironmentValue(parent.appendingPathComponent("editor-state").path,
                                                               for: "GUAVA_EDITOR_STATE_DIRECTORY"))
    }

    func restore() {
        #expect(WorkbenchUITestSupport.setEnvironmentValue(previousState, for: "GUAVA_EDITOR_STATE_DIRECTORY"))
        for (key, value) in previousDefaults {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: parent)
    }
}

@Suite("Project workspace", .serialized)
@MainActor
struct ProjectWorkspaceTests {
    @Test("with no saved project nothing opens and the window is the agent view with an empty project list")
    func projectless() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let state = try IsolatedProjectState("projectless")
        defer { state.restore() }
        let device = try Device.make()
        let context = EditorLaunchContext(renderDevice: device, inGameUI: try InGameUIHost(device: device),
                                          events: PlatformEventBridge(), shellState: nil)
        try context.restoreProjects()
        #expect(!context.isProjectLoaded && context.projects.isEmpty)
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: EditorLaunchRoot(context: context))
        graph.computeLayout(width: 1280, height: 720)
        for name in ["editor-view-switch", "editor-agent-thread", "editor-agent-composer", "projectless-open-folder"] {
            let node = try WorkbenchUITestSupport.named(name, in: graph.tree.root)
            #expect(node.absoluteFrame.width > 0 && node.absoluteFrame.maxY <= 720, "\(name)")
        }
        #expect(try WorkbenchUITestSupport.named("editor-agent-tasks", in: graph.tree.root).absoluteFrame.width == 232)
    } }

    @Test("folders open side by side, switch, close one at a time and come back on the next launch")
    func concurrentProjects() throws {
        let state = try IsolatedProjectState("projects")
        defer { state.restore() }
        let plain = state.parent.appendingPathComponent("Plain Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: false)
        try Data("notes".utf8).write(to: plain.appendingPathComponent("README.md"))
        let blank = try EditorProjectLifecycle.create(name: "Empty", parent: state.parent, template: .blank).directory
        let backend = try Device.make()
        defer { try? backend.waitUntilIdle() }
        do {
            let context = EditorLaunchContext(renderDevice: backend, inGameUI: try InGameUIHost(device: backend),
                                              events: PlatformEventBridge(), shellState: nil)
            defer { context.shutdown() }
            try context.openProject(directory: plain.path)
            #expect(FileManager.default.fileExists(atPath: plain.appendingPathComponent(".guava/project.json").path))
            #expect(try String(contentsOf: plain.appendingPathComponent("README.md"), encoding: .utf8) == "notes")
            let first = try #require(context.bundle?.app)
            try context.openProject(directory: blank.path)
            let second = try #require(context.bundle?.app)
            #expect(first !== second && context.loadedBundles.count == 2)
            #expect(context.projects.map(\.name) == ["Plain Folder", "Empty"])
            try context.openProject(directory: plain.path)
            #expect(context.bundle?.app === first && context.projects.count == 2)
            try context.activate(second.projectDirectory)
            #expect(context.bundle?.app === second)
            context.closeProject(second.projectDirectory)
            #expect(context.bundle?.app === first && context.projects.count == 1)
        }
        let saved = EditorProjectList.load()
        #expect(saved.paths.count == 1 && saved.active == saved.paths.first)
        let context = EditorLaunchContext(renderDevice: backend, inGameUI: try InGameUIHost(device: backend),
                                          events: PlatformEventBridge(), shellState: nil)
        defer { context.shutdown() }
        try context.restoreProjects()
        let restored = try #require(context.bundle?.app)
        #expect(restored.projectDirectory == saved.active)
        context.closeProject(restored.projectDirectory)
        #expect(!context.isProjectLoaded && context.projects.isEmpty)
        #expect(EditorProjectList.load().paths.isEmpty)
    }

    // ScriptBehavior libraries need the host Swift exports currently available
    // on macOS/Linux. Windows still exercises the project lifecycle above.
    #if os(macOS) || os(Linux)
    @Test("a compiled, playable project keeps its state while another project is in front")
    func projectRoundTrip() async throws {
        let state = try IsolatedProjectState("project-round-trip")
        defer { state.restore() }
        let bundle = Bundle(for: ProjectWorkspaceTestBundle.self).bundleURL
        let host = try #require([bundle, bundle.deletingLastPathComponent()]
            .map { $0.appendingPathComponent("EditorApp") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
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
        let backend = try Device.make()
        let context = EditorLaunchContext(renderDevice: backend,
                                          inGameUI: try InGameUIHost(device: backend),
                                          events: PlatformEventBridge(), shellState: nil)
        defer { context.shutdown(); try? backend.waitUntilIdle() }
        let crystal = try EditorProjectLifecycle.create(name: "Crystal Sample", parent: state.parent, template: .crystalRush)
        try context.openProject(directory: crystal.directory.path)
        let app = try #require(context.bundle?.app)
        app.workstation.scripts.setProjectTrusted(true)
        app.workstation.scripts.compileSelected()
        for _ in 0..<400 {
            if app.workstation.scripts.snapshot.selectedDocument?.loadedRevision != nil
                || app.workstation.scripts.snapshot.selectedDocument?.buildState.isFailed == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let doc = try #require(app.workstation.scripts.snapshot.selectedDocument)
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
        #if os(macOS)
        #expect(backend.backendAPI == .metal)
        #elseif os(Linux)
        #expect(backend.backendAPI == .vulkan)
        #endif
        let empty = try EditorProjectLifecycle.create(name: "Empty", parent: state.parent, template: .blank)
        try context.openProject(directory: empty.directory.path)
        let other = try #require(context.bundle?.app)
        #expect(other !== app && other.store.state.themeMode == .light)
        #expect(other.scene.entityCount == 0)
        #expect(other.workstation.scripts.snapshot.documents.isEmpty)
        try context.openProject(directory: crystal.directory.path)
        #expect(context.bundle?.app === app)
        #expect(app.scene.entityCount == 1)
        #expect(app.workstation.scripts.snapshot.documents.count == 1)
    }
    #endif
}
