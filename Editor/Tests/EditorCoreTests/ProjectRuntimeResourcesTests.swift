@testable import EditorCore
import Foundation
import Testing

@Suite("Project runtime resources", .serialized)
struct ProjectRuntimeResourcesTests {
    @Test("audio discovery ignores build directory case variants")
    func audioDiscoveryIgnoresBuildDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-runtime-resources-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("Assets/Audio", isDirectory: true)
        let generated = root.appendingPathComponent("Build/Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        try Data([1]).write(to: audio.appendingPathComponent("theme.wav"))
        try Data([2]).write(to: generated.appendingPathComponent("stale.wav"))

        let directories = ProjectRuntimeResources.discoverAudioSearchPaths(at: root.path)
        let paths = Set(directories.map { $0.standardizedFileURL.path })

        #expect(paths.contains(root.standardizedFileURL.path))
        #expect(paths.contains(audio.standardizedFileURL.path))
        #expect(!paths.contains(generated.standardizedFileURL.path))
    }
}
