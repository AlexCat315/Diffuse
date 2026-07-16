import CapabilityRuntime
@testable import EditorCore
import Foundation
import PluginRuntime
import XCTest

final class EditorPluginManagementSecurityTests: XCTestCase {
    func testInjectedPluginHostMustBeARegularExecutableAndRejectsSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)

        let nonExecutable = directory.appendingPathComponent("not-executable")
        try Data("host".utf8).write(to: nonExecutable)
        XCTAssertNil(EditorPluginHostLocator.resolve(injectedURL: nonExecutable))
        XCTAssertNil(EditorPluginHostLocator.resolve(injectedURL: directory))

        #if !os(Windows)
        let executable = directory.appendingPathComponent("GuavaPluginHost")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: executable.path)
        XCTAssertEqual(EditorPluginHostLocator.resolve(injectedURL: executable),
                       executable.standardizedFileURL.resolvingSymlinksInPath())

        let symbolicLink = directory.appendingPathComponent("linked-host")
        try FileManager.default.createSymbolicLink(at: symbolicLink,
                                                   withDestinationURL: executable)
        XCTAssertNil(EditorPluginHostLocator.resolve(injectedURL: symbolicLink))
        #endif
    }

    func testPendingApprovalAndEnabledStateAreNeverRestoredFromCoding() throws {
        let summary = makeSummary()
        let state = EditorState(
            pluginManagement: EditorPluginManagementState(
                phase: .awaitingAuthorization,
                candidate: summary,
                enabled: [summary],
                message: "approve me"
            )
        )

        let data = try JSONEncoder().encode(state)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(object["pluginManagement"])

        let restored = try JSONDecoder().decode(EditorState.self, from: data)
        XCTAssertEqual(restored.pluginManagement, .idle)
    }

    func testStorePublishesPluginManagementChanges() {
        let store = EditorStore()
        var notificationCount = 0
        let token = store.subscribe { _ in notificationCount += 1 }
        defer { store.unsubscribe(token) }

        let next = EditorPluginManagementState(phase: .failed,
                                               message: "rejected")
        store.dispatch(.setPluginManagementState(next))

        XCTAssertEqual(store.pluginManagement, next)
        XCTAssertEqual(notificationCount, 1)
    }

    private func makeSummary() -> EditorPluginInspectionSummary {
        let pluginID = "safe.management"
        let manifest = GuavaPluginManifest(id: pluginID,
                                           version: 1,
                                           name: "Management",
                                           description: "Test",
                                           access: .read,
                                           imports: [.sceneQuery])
        let contract = CapabilityContract(
            id: "\(pluginID).inspect",
            title: "Inspect",
            description: "Inspect safely",
            domain: "plugin",
            access: .read,
            releasePhase: .stable,
            inputSchema: .object(properties: [:], required: []),
            source: .plugin(pluginID)
        )
        return EditorPluginInspectionSummary(
            inspection: PluginInspection(manifest: manifest,
                                         componentHash: "component",
                                         witHash: "wit",
                                         contracts: [contract]),
            hasReusableAuthorization: false
        )
    }
}
