import Foundation
import Testing
@testable import EditorCore

@Suite("Project file boundaries")
struct ProjectFilePathTests {
    @Test("new paths inherit their canonical parent without accepting prefix siblings")
    func nonexistentPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guava-path-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        let candidate = alias.appendingPathComponent("Scripts/New.swift")
        #expect(ProjectFilePath.contains(candidate, in: project, includingRoot: false))
        #expect(ProjectFilePath.sameLocation(candidate, project.appendingPathComponent("Scripts/New.swift")))
        #expect(!ProjectFilePath.contains(root.appendingPathComponent("ProjectOther/New.swift"), in: project))
    }

    @Test("dangling script symlinks cannot redirect a future write outside the project")
    func danglingSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guava-path-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let link = project.appendingPathComponent("Escape.swift")
        try FileManager.default.createSymbolicLink(at: link,
            withDestinationURL: root.appendingPathComponent("Outside/Missing.swift"))
        #expect(!ProjectFilePath.contains(link, in: project))
    }
}
