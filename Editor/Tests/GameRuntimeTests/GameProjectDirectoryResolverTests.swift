import Foundation
@testable import GameRuntime
import Testing

@Suite("Game project directory resolver")
struct GameProjectDirectoryResolverTests {
    @Test("portable Player directory resolves its parent export")
    func resolvesPortablePlayerParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cove-player-resolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let playerDirectory = root.appendingPathComponent("Player", isDirectory: true)
        try FileManager.default.createDirectory(at: playerDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("build.json"))

        let resolved = GameProjectDirectoryResolver.resolve(
            arguments: ["CovePlayer"],
            environment: [:],
            bundleResourceURL: nil,
            executableURL: playerDirectory.appendingPathComponent("CovePlayer"),
            currentDirectoryURL: FileManager.default.temporaryDirectory
        )

        #expect(resolved == root.path)
    }

    @Test("explicit project arguments take priority over discovered layouts")
    func explicitProjectTakesPriority() {
        let resolved = GameProjectDirectoryResolver.resolve(
            arguments: ["CovePlayer", "--project", "/explicit/project"],
            environment: ["COVE_PROJECT_DIR": "/environment/project"],
            bundleResourceURL: URL(fileURLWithPath: "/bundle"),
            executableURL: URL(fileURLWithPath: "/export/Player/CovePlayer"),
            currentDirectoryURL: URL(fileURLWithPath: "/working")
        )

        #expect(resolved == "/explicit/project")
    }

    @Test("argv zero discovers a portable export when Bundle has no executable URL")
    func resolvesPortableParentFromArgumentZero() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cove-player-argv0-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = root.appendingPathComponent("Player/CovePlayer")
        try FileManager.default.createDirectory(at: player.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("build.json"))

        let resolved = GameProjectDirectoryResolver.resolve(
            arguments: [player.path],
            environment: [:],
            bundleResourceURL: nil,
            executableURL: nil,
            currentDirectoryURL: FileManager.default.temporaryDirectory
        )

        #expect(resolved == root.path)
    }
}
