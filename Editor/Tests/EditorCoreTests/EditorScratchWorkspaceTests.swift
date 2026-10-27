import Foundation
import Testing
@testable import EditorCore

/// The window falls back to a scratch workspace when no project is open. These
/// tests pin the two halves of that promise: the editor really runs in it, and
/// it really is not a project.
@Suite("Scratch workspace", .serialized)
@MainActor
struct EditorScratchWorkspaceTests {
    @Test("the scratch workspace opens a real editor")
    func opensEditor() throws {
        let directory = try EditorScratchWorkspace.prepare()
        let app = try EditorApplication(projectDirectory: directory.path)
        defer { app.shutdown() }

        #expect(app.isUntitledWorkspace)
        // The workbench, the agent and the script workspace all need these; an
        // editor that opened but left them empty would be the shell the user
        // rejected.
        #expect(app.store.state.content == .files || app.store.state.content == .scene)
        // The agent is a plugin, so the scratch editor must carry a plugin
        // session of its own: that is what makes it usable with no project.
        #expect(app.pluginSession.authorizationStore.storageURL.path
            .hasPrefix(directory.standardizedFileURL.resolvingSymlinksInPath().path))
    }

    @Test("the scratch workspace is never mistaken for a project")
    func isNotAProject() throws {
        let directory = try EditorScratchWorkspace.prepare()
        #expect(EditorScratchWorkspace.isScratch(directory.path))

        // Opening it must not turn it into something the launcher would list,
        // and a descriptor left by an earlier build must not survive the open.
        let descriptor = directory.appendingPathComponent(".cove/project.json")
        #expect(!FileManager.default.fileExists(atPath: descriptor.path))

        let app = try EditorApplication(projectDirectory: directory.path)
        defer { app.shutdown() }

        #expect(!FileManager.default.fileExists(atPath: descriptor.path))
        // `inspect` succeeds because the folder has a `.cove` cache directory,
        // but with no descriptor it has no name and no identity: nothing can
        // present it as a project the user opened.
        #expect(try EditorProjectLifecycle.inspect(directory, validateScene: false).descriptor == nil)
    }

    @Test("a real project is not the scratch workspace")
    func realProjectIsNotScratch() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("cove-scratch-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let created = try EditorProjectLifecycle.create(name: "Real", parent: parent)

        #expect(!EditorScratchWorkspace.isScratch(created.directory.path))
        #expect(created.directory.path != EditorScratchWorkspace.canonicalPath())
    }
}
