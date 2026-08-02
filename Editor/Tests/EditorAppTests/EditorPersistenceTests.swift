import Foundation
import Testing
@testable import EditorApp

@Suite("Editor persistence")
struct EditorPersistenceTests {
    @Test("Invalid persisted state is quarantined instead of deleted")
    func invalidStateIsQuarantined() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-editor-persistence-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("editor_shell_state.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("{ malformed state".utf8)
        try original.write(to: url, options: .atomic)

        let quarantinedURL = try #require(
            EditorRootViewFactory.quarantinePersistenceFile(
                at: url,
                label: "test state",
                reason: "invalid JSON"
            )
        )

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: quarantinedURL.path))
        #expect(try Data(contentsOf: quarantinedURL) == original)
        #expect(quarantinedURL.lastPathComponent.hasPrefix("editor_shell_state.corrupt-"))
        #expect(quarantinedURL.pathExtension == "json")
    }

    @Test("Quarantine is a no-op when persisted state is absent")
    func absentStateIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-editor-persistence-absent-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let result = EditorRootViewFactory.quarantinePersistenceFile(
            at: url,
            label: "test state",
            reason: "missing"
        )

        #expect(result == nil)
        #expect((try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
    }
}
