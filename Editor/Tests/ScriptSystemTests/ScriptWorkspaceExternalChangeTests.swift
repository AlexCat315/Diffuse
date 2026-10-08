import Foundation
import ScriptRuntime
import Testing
import GuavaUICompose
@testable import EditorCore

@Suite("Script workspace external changes", .serialized)
struct ScriptWorkspaceExternalChangeTests {
    @Test("Dismissing setup errors preserves health; retry and shutdown reset presentation")
    @MainActor
    func languageServiceHealthAndDismissal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guava-script-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DynamicScriptManager(projectDirectory: root.path, scriptRuntime: ScriptRuntime(),
            engineModulePaths: [], scriptTrustStorageURL: root.appendingPathComponent("trust.json"))
        _ = try manager.createScript(name: "Service", source: "let value = 1")
        let model = try ScriptWorkspaceModel(manager: manager)
        defer { model.shutdown() }
        model.startLanguageService()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.snapshot.languageServiceState == .starting && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .unavailable = model.snapshot.languageServiceState else {
            Issue.record("Missing built modules must report unavailable")
            return
        }
        let failure = model.snapshot.languageServiceState
        model.dismissLanguageServiceMessage()
        #expect(model.snapshot.languageServiceState == failure)
        #expect(model.snapshot.isLanguageServiceMessageDismissed)
        model.retryLanguageService()
        #expect(model.snapshot.languageServiceState == .starting)
        #expect(!model.snapshot.isLanguageServiceMessageDismissed)
        model.shutdown()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.snapshot.languageServiceState == .inactive)
    }

    @Test("Typing and deleting back to saved contents clears dirty state without reusing a root")
    func dirtyContentReversion() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("guava-script-dirty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let manager = DynamicScriptManager(projectDirectory: project.path, scriptRuntime: ScriptRuntime(),
            engineModulePaths: [], scriptTrustStorageURL: project.appendingPathComponent("trust.json"))
        _ = try manager.createScript(name: "Revert", source: "let emoji = \"😀\"\n")
        let model = try ScriptWorkspaceModel(manager: manager)
        let original = try #require(model.snapshot.selectedDocument?.source)
        let changed = original.insert("x", atCharacterIndex: 3)
        model.updateSelectedSource(changed)
        #expect(model.snapshot.selectedDocument?.isDirty == true)
        let restored = changed.delete(characterRange: 3..<4)
        #expect(restored != original)
        model.updateSelectedSource(restored)
        #expect(model.snapshot.selectedDocument?.isDirty == false)
        model.updateSelectedSource(TextBuffer(original.stringValue))
        #expect(model.snapshot.selectedDocument?.isDirty == false)
    }
    @Test("clean documents reload while dirty documents require conflict resolution")
    func reconcilesExternalEdits() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-script-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let manager = DynamicScriptManager(
            projectDirectory: project.path,
            scriptRuntime: ScriptRuntime(),
            engineModulePaths: [],
            scriptTrustStorageURL: project.appendingPathComponent("user-trust.json")
        )
        let initial = "import ScriptRuntime\n// initial\n"
        let fileURL = try manager.createScript(name: "Watched", source: initial)
        let model = try ScriptWorkspaceModel(manager: manager)

        let firstExternalEdit = "import ScriptRuntime\n// changed outside\n"
        try firstExternalEdit.write(to: fileURL, atomically: true, encoding: .utf8)
        model.refreshFromDisk()

        #expect(model.snapshot.selectedDocument?.source.stringValue == firstExternalEdit)
        #expect(model.snapshot.selectedDocument?.isDirty == false)

        let editorEdit = "import ScriptRuntime\n// changed in editor\n"
        let secondExternalEdit = "import ScriptRuntime\n// changed outside again\n"
        model.updateSelectedSource(TextBuffer(editorEdit))
        try secondExternalEdit.write(to: fileURL, atomically: true, encoding: .utf8)
        model.refreshFromDisk()

        #expect(model.snapshot.selectedDocument?.source.stringValue == editorEdit)
        #expect(model.snapshot.selectedDocument?.externalChange == .modifiedOnDisk(source: secondExternalEdit))

        model.resolveSelectedExternalChange(useDiskVersion: true)
        #expect(model.snapshot.selectedDocument?.source.stringValue == secondExternalEdit)
        #expect(model.snapshot.selectedDocument?.externalChange == ScriptExternalChangeState.none)
        #expect(model.snapshot.selectedDocument?.isDirty == false)
    }
}
