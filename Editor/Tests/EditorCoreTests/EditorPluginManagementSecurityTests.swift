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
        let executable = directory.appendingPathComponent("DiffusePluginHost")
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
        let state = EditorState {
            $0.assistant.pluginManagement = EditorPluginManagementState(
                phase: .awaitingAuthorization,
                candidate: summary,
                installed: [summary],
                message: "approve me"
            )
        }

        let data = try JSONEncoder().encode(state)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(object["pluginManagement"])

        let restored = try JSONDecoder().decode(EditorState.self, from: data)
        XCTAssertEqual(restored.assistant.pluginManagement, .idle)
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

    func testLanguageFormattingContributionsAreValidated() throws {
        var grammar: [[String: Any]] = [
            ["pattern": "%.*$", "token": "comment"],
            ["pattern": "\\\\section\\{([^}]*)\\}", "token": "keyword"],
        ]
        var outline: [[String: Any]] = [
            ["pattern": "\\\\section\\{([^}]*)\\}", "level": 2],
        ]
        var language: [String: Any] = [
            "id": "latex",
            "title": "LaTeX",
            "extensions": ["tex"],
            "grammar": ["rules": grammar],
            "outline": ["rules": outline],
            "format": ["entryPoint": "format"],
        ]
        XCTAssertNoThrow(try PluginManifestValidator.decodeAndValidate(validManifest(language: language)))

        grammar[0]["token"] = "colour"
        language["grammar"] = ["rules": grammar]
        assertInvalidContribution(language: language)

        grammar[0] = ["pattern": "(", "token": "comment"]
        language["grammar"] = ["rules": grammar]
        assertInvalidContribution(language: language)

        outline[0] = ["pattern": "\\\\section", "level": 2]
        language["grammar"] = ["rules": [["pattern": "%.*$", "token": "comment"]]]
        language["outline"] = ["rules": outline]
        assertInvalidContribution(language: language)

        for level in [0, 7] {
            outline[0] = ["pattern": "\\\\section\\{([^}]*)\\}", "level": level]
            language["outline"] = ["rules": outline]
            assertInvalidContribution(language: language)
        }

        language["outline"] = ["rules": [["pattern": "\\\\section\\{([^}]*)\\}", "level": 2]]]
        for entryPoint in ["Format", "-format", "format_1"] {
            language["format"] = ["entryPoint": entryPoint]
            assertInvalidContribution(language: language)
        }
    }

    func testFormatEntryPointMustMatchTheDocumentInputContract() throws {
        let root = try makeFormattingPackage(wit: """
        package safe:formatter;
        interface capabilities {
          record format-input { text: string }
          format: func(input: format-input) -> string;
        }
        world plugin {
          export capabilities;
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNoThrow(try PluginPackageLoader().load(at: root))

        let missing = try makeFormattingPackage(wit: """
        package safe:formatter;
        interface capabilities {
          record formatter-input { text: string }
          formatter: func(input: formatter-input) -> string;
        }
        world plugin {
          export capabilities;
        }
        """)
        defer { try? FileManager.default.removeItem(at: missing) }
        XCTAssertThrowsError(try PluginPackageLoader().load(at: missing)) { error in
            XCTAssertEqual(error as? PluginManifestValidationError,
                           .invalidContribution("cove.language/v1"))
        }

        let wrongInput = try makeFormattingPackage(wit: """
        package safe:formatter;
        interface capabilities {
          record format-input { document: string }
          format: func(input: format-input) -> string;
        }
        world plugin {
          export capabilities;
        }
        """)
        defer { try? FileManager.default.removeItem(at: wrongInput) }
        XCTAssertThrowsError(try PluginPackageLoader().load(at: wrongInput)) { error in
            XCTAssertEqual(error as? PluginManifestValidationError,
                           .invalidContribution("cove.language/v1"))
        }
    }

    private func validManifest(language: [String: Any]) -> Data {
        let manifest: [String: Any] = [
            "id": "safe.formatter",
            "version": 1,
            "name": "Formatter",
            "description": "Formatting fixture",
            "access": "read",
            "imports": [],
            "composable_host_capabilities": [],
            "contributes": ["cove.language/v1": [language]],
        ]
        return (try? JSONSerialization.data(withJSONObject: manifest)) ?? Data()
    }

    private func assertInvalidContribution(language: [String: Any],
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
        XCTAssertThrowsError(try PluginManifestValidator.decodeAndValidate(validManifest(language: language)),
                             file: file, line: line) { error in
            XCTAssertEqual(error as? PluginManifestValidationError,
                           .invalidContribution("cove.language/v1"),
                           file: file, line: line)
        }
    }

    private func makeFormattingPackage(wit: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathExtension("coveplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let language: [String: Any] = [
            "id": "latex",
            "title": "LaTeX",
            "extensions": ["tex"],
            "format": ["entryPoint": "format"],
        ]
        try validManifest(language: language).write(to: root.appendingPathComponent("plugin.json"))
        try Data([0x00, 0x61, 0x73, 0x6D, 0x0D, 0x00, 0x01, 0x00])
            .write(to: root.appendingPathComponent("component.wasm"))
        try Data(wit.utf8).write(to: root.appendingPathComponent("capabilities.wit"))
        return root
    }

    private func makeSummary() -> EditorPluginInspectionSummary {
        let pluginID = "safe.management"
        let manifest = CovePluginManifest(id: pluginID,
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
