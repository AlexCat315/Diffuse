import AIRuntime
@testable import EditorCore
import Foundation
import PluginRuntime
import Testing

/// The bundled plugins' own contributions, run in a real plugin host against
/// real data: Git reads a real repository for the assistant, and Swift Support
/// shows this repository's Package.resolved.
@Suite("Bundled plugin contributions", .serialized)
@MainActor
struct BundledContributionsTests {
    @Test func theAssistantReadsTheWorkingTreeThroughGit() async throws {
        let project = try directory()
        defer { try? FileManager.default.removeItem(at: project) }
        try git(["init", "--quiet", "--initial-branch=main"], in: project)
        try Data("tracked\n".utf8).write(to: project.appendingPathComponent("tracked.txt"))
        try git(["add", "tracked.txt"], in: project)
        try git(["-c", "user.name=Cove", "-c", "user.email=cove@example.invalid", "commit", "--quiet", "-m", "Start"], in: project)
        try Data("changed\n".utf8).write(to: project.appendingPathComponent("tracked.txt"))
        try Data("new\n".utf8).write(to: project.appendingPathComponent("notes.txt"))

        let app = try await application(project: project, plugins: ["studio.ai", "studio.git", "studio.lore"])
        defer { app.shutdown() }
        #expect(app.agentCatalog.agent(id: "")?.packageContexts == ["git", "lore"])
        let target = EditorAgentTaskTarget(documentID: app.store.state.document.identity, sceneRevision: app.store.sceneRevision,
                                           content: .files, selectedEntityIDs: [], primaryEntityID: nil)
        let sections = await app.agentContextSections(target: target)
        let tree = try #require(sections.first { $0.title == "Working Tree" })
        #expect(tree.text.contains("Branch: main"))
        #expect(tree.text.contains(" M tracked.txt"))
        #expect(tree.text.contains("?? notes.txt"))
        // This is no Lore workspace, so Lore has nothing to add and nothing to complain about.
        #expect(sections.map(\.title) == ["Working Tree"])
        #expect(!app.store.state.output.consoleEntries.contains { $0.message.contains("context was left out") })
    }

    @Test func swiftSupportShowsThePinnedPackages() async throws {
        let project = try directory()
        defer { try? FileManager.default.removeItem(at: project) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let resolved = try Data(contentsOf: repository.appendingPathComponent("Package.resolved"))
        try resolved.write(to: project.appendingPathComponent("Package.resolved"))
        let pins = try #require((try JSONSerialization.jsonObject(with: resolved) as? [String: Any])?["pins"] as? [[String: Any]])

        let app = try await application(project: project, plugins: ["studio.swift-support"])
        defer { app.shutdown() }
        app.workstation.documents.open("Package.resolved")
        let view = try #require(app.workbenchCatalog.documentViews(forPath: "Package.resolved").first)
        #expect(view.title == "Dependencies")
        let session = app.viewSession(for: view, path: "Package.resolved")
        for _ in 0..<500 where session.snapshot.isBusy || session.snapshot.ui == nil && session.snapshot.failure == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.snapshot.failure == nil)
        let table = try #require(tables(in: session.snapshot.ui).first)
        #expect(table.columns == ["Package", "Version", "Revision", "Location"])
        #expect(table.rows.map { $0.cells[0] } == pins.compactMap { $0["identity"] as? String })
        let first = try #require(pins.first?["state"] as? [String: Any])
        #expect(table.rows.first?.cells[1] == first["version"] as? String)
    }

    // MARK: Fixtures

    private func application(project: URL, plugins: [String]) async throws -> EditorApplication {
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".cove"), withIntermediateDirectories: true)
        let app = try EditorApplication(projectDirectory: project.path, seedPreviewScene: false,
                                        trustedPluginHostExecutableURL: try #require(EditorPluginHostLocator.resolve()))
        for id in plugins { await app.setBundledPlugin(try #require(BundledPlugins.plugin(id: id)), enabled: true) }
        return app
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = try #require(ContributionTool.locate("git")).executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }

    private func tables(in node: UINode?) -> [UINode.Table] {
        guard let node else { return [] }
        switch node.kind {
        case let .table(table): return [table]
        case let .column(stack), let .row(stack): return stack.children.flatMap(tables)
        case let .scroll(child): return tables(in: child)
        case let .section(_, children): return children.flatMap(tables)
        case let .disclosure(disclosure): return disclosure.children.flatMap(tables)
        default: return []
        }
    }
}
