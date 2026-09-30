import Foundation
import ScriptRuntime
import Testing
@testable import EditorCore

@Suite("Script workspace external changes", .serialized)
struct ScriptWorkspaceExternalChangeTests {
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

        #expect(model.snapshot.selectedDocument?.source == firstExternalEdit)
        #expect(model.snapshot.selectedDocument?.isDirty == false)

        let editorEdit = "import ScriptRuntime\n// changed in editor\n"
        let secondExternalEdit = "import ScriptRuntime\n// changed outside again\n"
        model.updateSelectedSource(editorEdit)
        try secondExternalEdit.write(to: fileURL, atomically: true, encoding: .utf8)
        model.refreshFromDisk()

        #expect(model.snapshot.selectedDocument?.source == editorEdit)
        #expect(model.snapshot.selectedDocument?.externalChange == .modifiedOnDisk(source: secondExternalEdit))

        model.resolveSelectedExternalChange(useDiskVersion: true)
        #expect(model.snapshot.selectedDocument?.source == secondExternalEdit)
        #expect(model.snapshot.selectedDocument?.externalChange == ScriptExternalChangeState.none)
        #expect(model.snapshot.selectedDocument?.isDirty == false)
    }
}
