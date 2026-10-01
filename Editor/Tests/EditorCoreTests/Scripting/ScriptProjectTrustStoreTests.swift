import Foundation
import Testing
@testable import EditorCore

@Suite("Script trust state isolation")
struct ScriptProjectTrustStoreTests {
    @Test("isolated editor state persists trust outside the project and keeps explicit storage precedence")
    func isolatedState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guava-trust-state-\(UUID())")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        let environment = ["GUAVA_EDITOR_STATE_DIRECTORY": state.path]
        let store = ScriptProjectTrustStore(environment: environment)
        #expect(store.state(for: project.path) == .untrusted)
        try store.setTrusted(true, projectDirectory: project.path)
        #expect(FileManager.default.fileExists(atPath: state.appendingPathComponent("script-workspace-trust.json").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: project.path).isEmpty)
        #expect(ScriptProjectTrustStore(environment: environment).state(for: project.path) == .trusted)
        let explicitURL = root.appendingPathComponent("explicit-trust.json")
        let separate = ScriptProjectTrustStore(storageURL: explicitURL, environment: environment)
        #expect(separate.state(for: project.path) == .untrusted)
        try separate.setTrusted(true, projectDirectory: project.path)
        #expect(FileManager.default.fileExists(atPath: explicitURL.path))
    }
}
