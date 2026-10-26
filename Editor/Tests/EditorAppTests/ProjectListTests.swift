import Foundation
import Testing
@testable import EditorUI

@Suite("Saved project list")
struct ProjectListTests {
    @Test("paths are normalized and deduplicated, and the front project must be one of them")
    func savedProjects() throws {
        let domain = "GuavaProjectListTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let canonical = EditorProjectList.canonicalPath(parent.path)
        EditorProjectList(paths: [parent.path, parent.appendingPathComponent("child/..").path, ""],
                          active: parent.path).save(defaults: defaults)
        let loaded = EditorProjectList.load(defaults: defaults)
        #expect(loaded.paths == [canonical])
        #expect(loaded.active == canonical)
        EditorProjectList(paths: [], active: parent.path).save(defaults: defaults)
        #expect(EditorProjectList.load(defaults: defaults).active == nil)
        EditorProjectList(paths: [parent.path], active: nil).save(defaults: defaults)
        #expect(EditorProjectList.load(defaults: defaults) == EditorProjectList(paths: [canonical], active: nil))
        #expect(FileManager.default.fileExists(atPath: parent.path))
    }
}
