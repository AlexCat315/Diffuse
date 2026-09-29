import Foundation
import ScriptRuntime
import Testing
@testable import EditorCore

@Suite("Dynamic script manager", .serialized)
struct DynamicScriptManagerTests {
    @Test("creating a duplicate script never overwrites its source")
    func duplicateCreationDoesNotOverwrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DynamicScriptManager(projectDirectory: root.path,
                                           scriptRuntime: ScriptRuntime(),
                                           engineModulePaths: [])

        let url = try manager.createScript(name: "Player Controller", source: "first")
        #expect(try manager.readSource(at: url) == "first")
        #expect(throws: ScriptFileError.alreadyExists("Player Controller")) {
            try manager.createScript(name: "Player Controller", source: "second")
        }
        #expect(try manager.readSource(at: url) == "first")
    }

    @Test("script names cannot escape the Scripts directory")
    func rejectsPathSeparatorsInScriptNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DynamicScriptManager(projectDirectory: root.path,
                                           scriptRuntime: ScriptRuntime(),
                                           engineModulePaths: [])

        #expect(throws: ScriptFileError.invalidName("../Outside")) {
            try manager.createScript(name: "../Outside", source: "")
        }
    }
}