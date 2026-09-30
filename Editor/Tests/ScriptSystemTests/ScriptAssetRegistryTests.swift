import Foundation
import ScriptRuntime
import Testing
@testable import EditorCore

@Suite("Script asset identity", .serialized)
struct ScriptAssetRegistryTests {
    @Test("renaming a source file preserves its asset identity and legacy aliases")
    func renamePreservesIdentity() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-script-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let trustURL = project.appendingPathComponent("user-trust.json")
        let manager = DynamicScriptManager(projectDirectory: project.path,
                                           scriptRuntime: ScriptRuntime(),
                                           engineModulePaths: [],
                                           scriptTrustStorageURL: trustURL)
        let source = "import ScriptRuntime\nstruct GameScript: ScriptBehavior {}\n"
        let originalURL = try manager.createScript(name: "Player", source: source)
        let original = try #require(manager.scanScriptFiles().first)
        let renamedURL = originalURL.deletingLastPathComponent()
            .appendingPathComponent("Runner.swift")

        try FileManager.default.moveItem(at: originalURL, to: renamedURL)
        let renamed = try #require(manager.scanScriptFiles().first)

        #expect(renamed.assetID == original.assetID)
        #expect(renamed.identifier == original.identifier)
        #expect(renamed.legacyIdentifiers.contains("scripts.player"))
        #expect(renamed.legacyIdentifiers.contains("scripts.runner"))
    }

    @Test("workspace trust is fail-closed and stored outside project state")
    func trustIsExplicitAndPersistent() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-script-trust-project-\(UUID().uuidString)", isDirectory: true)
        let userStore = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-script-trust-user-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: userStore)
        }
        let first = DynamicScriptManager(projectDirectory: project.path,
                                         scriptRuntime: ScriptRuntime(),
                                         engineModulePaths: [],
                                         scriptTrustStorageURL: userStore)
        #expect(first.projectTrustState == .untrusted)

        try first.setProjectTrusted(true)
        let reopened = DynamicScriptManager(projectDirectory: project.path,
                                            scriptRuntime: ScriptRuntime(),
                                            engineModulePaths: [],
                                            scriptTrustStorageURL: userStore)
        #expect(reopened.projectTrustState == .trusted)

        try reopened.setProjectTrusted(false)
        #expect(reopened.projectTrustState == .untrusted)
    }
}
