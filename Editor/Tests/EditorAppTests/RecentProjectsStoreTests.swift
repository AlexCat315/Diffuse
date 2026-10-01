import Foundation
import Testing
@testable import EditorApp

@Suite("Recent projects")
struct RecentProjectsStoreTests {
    @Test("paths are normalized, deduplicated, bounded, and removed without deleting files")
    func recentPaths() throws {
        let domain = "GuavaRecentProjectsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        RecentProjectsStore.record(parent.path, defaults: defaults)
        RecentProjectsStore.record(parent.appendingPathComponent("child/..").path, defaults: defaults)
        #expect(RecentProjectsStore.all(defaults: defaults).count == 1)
        RecentProjectsStore.remove(parent.path, defaults: defaults)
        #expect(RecentProjectsStore.all(defaults: defaults).isEmpty)
        #expect(FileManager.default.fileExists(atPath: parent.path))
        for index in 0..<10 { RecentProjectsStore.record(parent.appendingPathComponent("\(index)").path, defaults: defaults) }
        #expect(RecentProjectsStore.all(defaults: defaults).count == 8)
        #expect(RecentProjectsStore.all(defaults: defaults).first?.hasSuffix("/9") == true)
    }
}
