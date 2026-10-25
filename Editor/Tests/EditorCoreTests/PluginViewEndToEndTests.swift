@testable import EditorCore
import Foundation
import PluginRuntime
import Testing

/// The example Checklist plugin, built to WebAssembly and run in a real plugin
/// host: state goes out and comes back, events change the tree, and the CSV
/// view reads the open document. Build the package with
/// `./guava studio plugin-build examples/Plugins/Checklist --output <path>` and
/// point `GUAVA_CHECKLIST_PLUGIN` at it.
@Suite("Plugin views end to end", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["GUAVA_CHECKLIST_PLUGIN"] != nil))
@MainActor
struct PluginViewEndToEndTests {
    @Test func checklistKeepsItsStateAcrossEvents() async throws {
        let (app, project) = try await enableChecklist()
        defer { app.shutdown(); try? FileManager.default.removeItem(at: project) }
        let panel = try #require(app.workbenchCatalog.panel(id: "checklist"))
        let session = app.viewSession(for: panel)
        await settle(session)
        #expect(session.snapshot.failure == nil)
        #expect(session.values["draft"] == .string(""))
        #expect(texts(in: session).contains("Nothing here yet"))

        session.setValue(.string("Ship the view protocol"), for: "draft")
        session.send(action: "add")
        await settle(session)
        #expect(texts(in: session).contains("Ship the view protocol"))
        #expect(session.values["draft"] == .string(""))

        session.setValue(.string("Write the spec"), for: "draft")
        session.send(action: "add")
        await settle(session)
        session.send(action: "toggle", arguments: .object(["index": .number(0)]), value: .bool(true))
        await settle(session)
        #expect(session.values["done-0"] == .bool(true))
        #expect(texts(in: session).contains("1 open"))

        var notes: [String] = []
        app.setPluginNotificationHandler { text, _ in notes.append(text) }
        session.send(action: "clear")
        await settle(session)
        #expect(notes == ["Cleared 1 item(s)"])
        #expect(!texts(in: session).contains("Ship the view protocol"))
        #expect(texts(in: session).contains("Write the spec"))
    }

    @Test func csvTableReadsTheOpenDocument() async throws {
        let (app, project) = try await enableChecklist()
        defer { app.shutdown(); try? FileManager.default.removeItem(at: project) }
        try Data("name,size\nalpha,1\nbeta,2\n".utf8).write(to: project.appendingPathComponent("data.csv"))
        app.workstation.documents.open("data.csv")
        let view = try #require(app.workbenchCatalog.documentViews(forPath: "data.csv").first)
        let session = app.viewSession(for: view, path: "data.csv")
        await settle(session)
        #expect(session.snapshot.failure == nil)
        #expect(texts(in: session).contains("2 rows"))
        #expect(tables(in: session).first?.rows.map(\.cells) == [["alpha", "1"], ["beta", "2"]])
    }

    // MARK: Fixtures

    private func enableChecklist() async throws -> (EditorApplication, URL) {
        let package = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GUAVA_CHECKLIST_PLUGIN"]))
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try EditorApplication(projectDirectory: project.path, seedPreviewScene: false,
                                        trustedPluginHostExecutableURL: try #require(EditorPluginHostLocator.resolve()))
        let inspection = try app.inspectPlugin(at: package)
        _ = try await app.enablePlugin(at: package, authorization: try app.makePluginAuthorization(afterUserApprovalOf: inspection))
        return (app, project)
    }

    private func settle(_ session: PluginViewSession) async {
        for _ in 0..<500 {
            await Task.yield()
            if !session.snapshot.isBusy { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func texts(in session: PluginViewSession) -> [String] {
        var result: [String] = []
        session.snapshot.ui?.visit { node in
            switch node.kind {
            case let .text(text): result.append(text.text)
            case let .badge(text, _): result.append(text)
            default: break
            }
        }
        return result
    }

    private func tables(in session: PluginViewSession) -> [UINode.Table] {
        var result: [UINode.Table] = []
        session.snapshot.ui?.visit { if case let .table(table) = $0.kind { result.append(table) } }
        return result
    }
}

private extension UINode {
    func visit(_ body: (UINode) -> Void) {
        body(self)
        switch kind {
        case let .column(stack), let .row(stack): stack.children.forEach { $0.visit(body) }
        case let .scroll(child): child.visit(body)
        case let .section(_, children): children.forEach { $0.visit(body) }
        case let .disclosure(disclosure): disclosure.children.forEach { $0.visit(body) }
        default: break
        }
    }
}
