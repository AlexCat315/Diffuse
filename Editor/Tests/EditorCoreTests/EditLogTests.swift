@testable import EditorCore
import Foundation
import IntentRuntime
import XCTest

final class EditLogTests: XCTestCase {
    func testAppendCreatesParentAndPreservesJSONLOrder() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-edit-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let log = EditLog(projectDirectory: project.path)
        let first = makeEdit(id: "first", revision: 1)
        let second = makeEdit(id: "second", revision: 2)

        try log.append(first)
        try log.append(second)

        let logURL = project.appendingPathComponent(".guava/edit_log.jsonl")
        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let edits = try lines.map { try decoder.decode(Edit.self, from: Data($0.utf8)) }
        XCTAssertEqual(edits.map(\.id), ["first", "second"])
    }

    func testAppendSurfacesUnwritableProjectLayout() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-edit-log-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: project) }
        try Data("not-a-directory".utf8).write(to: project)
        let log = EditLog(projectDirectory: project.path)

        XCTAssertThrowsError(try log.append(makeEdit(id: "blocked", revision: 1)))
    }

    private func makeEdit(id: String, revision: UInt64) -> Edit {
        Edit(
            id: id,
            transactionID: "transaction-\(id)",
            summary: id,
            mutationSummaries: ["rename"],
            changedDomains: ["scene"],
            provenance: EditProvenance(
                authorKind: .ai,
                timestamp: Date(timeIntervalSince1970: TimeInterval(revision))
            ),
            revisionBefore: WorldRevisionSnapshot(sceneRevision: revision - 1),
            revisionAfter: WorldRevisionSnapshot(sceneRevision: revision)
        )
    }
}
