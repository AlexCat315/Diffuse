import CapabilityRuntime
@testable import EditorCore
import Foundation
import PluginRuntime
import XCTest

final class EditorPluginAuthorizationStoreTests: XCTestCase {
    func testRecordsOnlyExactInspectionAndNeverTreatsChangedSchemaAsAuthorized() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let inspection = makeInspection(maximumLength: 32)
        let authorization = try PluginAuthorizationRecord(
            inspection: inspection,
            authorisedAt: Date(timeIntervalSince1970: 5)
        )
        let store = EditorPluginAuthorizationStore(projectDirectory: directory.path)
        XCTAssertNil(store.authorization(for: inspection))

        try store.record(authorization)
        XCTAssertEqual(store.authorization(for: inspection), authorization)
        #if !os(Windows)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: store.storageURL.path)[.posixPermissions]
                as? NSNumber,
            NSNumber(value: 0o600)
        )
        #endif

        let reopened = EditorPluginAuthorizationStore(projectDirectory: directory.path)
        XCTAssertEqual(reopened.authorization(for: inspection), authorization)
        XCTAssertNil(reopened.authorization(for: makeInspection(maximumLength: 64)))
    }

    func testCorruptOrPreseededDuplicateStorageFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let guava = directory.appendingPathComponent(".guava", isDirectory: true)
        try FileManager.default.createDirectory(at: guava,
                                                withIntermediateDirectories: true)
        let inspection = makeInspection(maximumLength: 32)
        let authorization = try PluginAuthorizationRecord(inspection: inspection)
        let encodedRecord = try JSONEncoder().encode(authorization)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedRecord) as? [String: Any]
        )
        let document: [String: Any] = [
            "format_version": 1,
            "records": [object, object],
        ]
        try JSONSerialization.data(withJSONObject: document).write(
            to: guava.appendingPathComponent("plugin_authorizations.json")
        )

        let store = EditorPluginAuthorizationStore(projectDirectory: directory.path)
        XCTAssertTrue(store.allRecords().isEmpty)
        XCTAssertNil(store.authorization(for: inspection))
        XCTAssertNotNil(store.loadWarning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))
        let quarantinedFiles = try FileManager.default.contentsOfDirectory(
            at: guava,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(quarantinedFiles.contains {
            $0.lastPathComponent.hasPrefix("plugin_authorizations.corrupt-")
                && $0.pathExtension == "json"
        })
    }

    func testUnknownStorageFormatIsQuarantinedInsteadOfSilentlyDiscarded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let guava = directory.appendingPathComponent(".guava", isDirectory: true)
        try FileManager.default.createDirectory(at: guava,
                                                withIntermediateDirectories: true)
        let storageURL = guava.appendingPathComponent("plugin_authorizations.json")
        try Data("{\"format_version\":2,\"records\":[]}".utf8).write(to: storageURL)

        let store = EditorPluginAuthorizationStore(projectDirectory: directory.path)

        XCTAssertTrue(store.allRecords().isEmpty)
        XCTAssertTrue(store.loadWarning?.contains("unsupported format version 2") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
    }

    private func makeInspection(maximumLength: Int) -> PluginInspection {
        let pluginID = "safe.persisted"
        let manifest = GuavaPluginManifest(id: pluginID,
                                           version: 1,
                                           name: "Persisted",
                                           description: "Test",
                                           access: .read)
        let contract = CapabilityContract(
            id: "\(pluginID).inspect",
            title: "Inspect",
            description: "Inspect safely",
            domain: "plugin",
            access: .read,
            releasePhase: .stable,
            inputSchema: .object(
                properties: ["query": .string(minLength: nil,
                                                maxLength: maximumLength)],
                required: ["query"]
            ),
            source: .plugin(pluginID)
        )
        return PluginInspection(manifest: manifest,
                                componentHash: "component",
                                witHash: "wit",
                                contracts: [contract])
    }
}
