import AssetPipeline
import Foundation
import Testing

@Suite("Project resource traversal")
struct ProjectResourceWalkerTests {
    @Test("pruning generated folders preserves every unrelated nested resource")
    func siblingDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guava-walk-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Build/Generated/ignored.png", "Assets/Audio/theme.wav", "Textures/kept.png"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
        }
        let files = try ProjectResourceWalker.files(in: root) { $0.lastPathComponent.lowercased() == "build" }
        #expect(Set(files.map(\.lastPathComponent)) == ["theme.wav", "kept.png"])
    }

    @Test("directory symlinks do not import resources outside the project or form traversal cycles")
    func symlinkBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guava-walk-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project")
        let outside = root.appendingPathComponent("Outside")
        for directory in [project, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data([1]).write(to: project.appendingPathComponent("kept.png"))
        try Data([2]).write(to: outside.appendingPathComponent("private.png"))
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("Alias"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("Loop"), withDestinationURL: project)
        let files = try ProjectResourceWalker.files(in: project) { _ in false }
        #expect(files.map(\.lastPathComponent) == ["kept.png"])
    }
}
