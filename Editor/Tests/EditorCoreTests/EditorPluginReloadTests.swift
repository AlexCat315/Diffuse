import CapabilityRuntime
@testable import EditorCore
import Foundation
import PluginRuntime
@testable import PluginWasmtimeRuntime
import XCTest

/// End-to-end reload coverage: a real `GuavaPluginHost` process, a component
/// compiled from the canonical fixture WAT, and the Editor's mount / reload /
/// stale-rejection paths.
@MainActor
final class EditorPluginReloadTests: XCTestCase {
    func testReloadRemountsUnchangedPackageAndSurfacesChangedPackage() async throws {
        var step = "locate host"
        do {
            let host = try pluginHostExecutable()
            step = "build package"
            let package = try makePluginPackage()
            defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }

            let project = FileManager.default.temporaryDirectory
                .appendingPathComponent("guava-plugin-reload-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: project) }
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

            step = "create application"
            let application = try EditorApplication(projectDirectory: project.path,
                                                    seedPreviewScene: false,
                                                    trustedPluginHostExecutableURL: host)
            defer { application.shutdown() }

            step = "inspect"
            let inspection = try application.inspectPlugin(at: package)
            step = "authorize"
            let authorization = try application.makePluginAuthorization(afterUserApprovalOf: inspection)
            step = "enable"
            _ = try await application.enablePlugin(at: package, authorization: authorization)
            XCTAssertTrue(application.pluginSession.manager.activeBindings.isEmpty)
            let opened = await application.handleMCPMessage(Data(
                #"{"action":"open_capability_session","session_id":"4394C8F4-96BF-48C7-880B-40B83D787DFC"}"#.utf8))
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: opened) as? [String: Any])
            XCTAssertEqual(response["ok"] as? Bool, true, String(describing: response))
            XCTAssertEqual(application.enabledPluginInspections().map(\.manifest.id),
                           ["safe.reloadtest"])
            let generationBefore = try XCTUnwrap(
                application.pluginSession.manager.activeBindings["safe.reloadtest"]?.hostGeneration
            )

            // Byte-identical package: one-step remount on the same host generation.
            step = "reload"
            try await application.reloadPlugin(id: "safe.reloadtest")
            XCTAssertEqual(application.enabledPluginInspections().map(\.manifest.id),
                           ["safe.reloadtest"])
            XCTAssertEqual(application.pluginSession.manager.activeBindings["safe.reloadtest"]?.hostGeneration,
                           generationBefore)

            // Changed package: rejected before unload, old generation stays mounted.
            step = "mutate manifest"
            var manifest = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: package.appendingPathComponent("plugin.json"))
                ) as? [String: Any]
            )
            manifest["version"] = 2
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
                .write(to: package.appendingPathComponent("plugin.json"))
            step = "reload stale package"
            do {
                try await application.reloadPlugin(id: "safe.reloadtest")
                XCTFail("expected a stale-authorization rejection")
            } catch {
                XCTAssertEqual(error as? EditorPluginCapabilityError,
                               .pluginAuthorizationStale("safe.reloadtest"))
            }
            XCTAssertEqual(application.enabledPluginInspections().map(\.manifest.id),
                           ["safe.reloadtest"])
            XCTAssertEqual(application.pluginSession.manager.activeBindings["safe.reloadtest"]?.hostGeneration,
                           generationBefore)

            // The management entry surfaces the changed build for re-authorization.
            step = "management reload"
            await application.reloadPluginFromManagement(id: "safe.reloadtest")
            XCTAssertEqual(application.store.state.assistant.pluginManagement.candidate?.id,
                           "safe.reloadtest")
            XCTAssertEqual(application.store.state.assistant.pluginManagement.phase,
                           .awaitingAuthorization)

            step = "approve replacement build"
            await application.authorizeAndEnableInspectedPlugin()
            XCTAssertEqual(application.store.state.assistant.pluginManagement.phase, .idle)
            XCTAssertEqual(application.enabledPluginInspections().first?.manifest.version, 2)

            step = "disable"
            try await application.disablePlugin(id: "safe.reloadtest")
            XCTAssertTrue(application.enabledPluginInspections().isEmpty)
        } catch {
            XCTFail("failed at step '\(step)': \(error)")
        }
    }

    func testDependenciesProtectDisableAndReloadRollsBackAfterGenerationLoss() async throws {
        let host = try pluginHostExecutable()
        let provider = try makePluginPackage()
        let dependent = try makePluginPackage(id: "safe.dependent", requires: [
            PluginRequirement(kind: .capability, id: "safe.reloadtest.inspect"),
        ])
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            for url in [provider.deletingLastPathComponent(), dependent.deletingLastPathComponent(), project] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let application = try EditorApplication(projectDirectory: project.path, seedPreviewScene: false,
                                                trustedPluginHostExecutableURL: host)
        defer { application.shutdown() }
        let dependentAuthorization = try application.makePluginAuthorization(
            afterUserApprovalOf: application.inspectPlugin(at: dependent))
        do {
            _ = try await application.enablePlugin(at: dependent, authorization: dependentAuthorization)
            XCTFail("Missing capability dependency must fail")
        } catch is UnmetPluginRequirements {}
        XCTAssertTrue(application.enabledPluginInspections().isEmpty)
        let providerAuthorization = try application.makePluginAuthorization(
            afterUserApprovalOf: application.inspectPlugin(at: provider))
        _ = try await application.enablePlugin(at: provider, authorization: providerAuthorization)
        try await application.activatePlugins(event: "onAITool:safe.reloadtest.inspect")
        _ = try await application.enablePlugin(at: dependent, authorization: dependentAuthorization)
        try await application.activatePlugins(event: "onAITool:safe.dependent.inspect")
        do {
            try await application.disablePlugin(id: "safe.reloadtest")
            XCTFail("A capability provider cannot be disabled while required")
        } catch let error as RequiredPluginStillNeeded {
            XCTAssertEqual(error.dependents, ["safe.dependent"])
        }
        do {
            try await application.revokePluginAuthorization(id: "safe.reloadtest")
            XCTFail("Rejected revocation must preserve the enabled authorization")
        } catch is RequiredPluginStillNeeded {}
        XCTAssertNotNil(try application.storedPluginAuthorization(for: application.inspectPlugin(at: provider)))
        let first = Task { @MainActor in try await application.reloadPlugin(id: "safe.reloadtest") }
        let second = Task { @MainActor in try await application.reloadPlugin(id: "safe.dependent") }
        try await first.value
        try await second.value
        XCTAssertEqual(application.enabledPluginInspections().count, 2)
        // Each plugin owns its process. Dropping the provider's host stops only
        // that plugin; its dependent keeps the process that loaded it.
        application.pluginSession.hosts.discard("safe.reloadtest")
        XCTAssertNil(application.pluginSession.hosts.existing("safe.reloadtest"))
        XCTAssertNotNil(application.pluginSession.hosts.existing("safe.dependent"))
        try await application.reloadPlugin(id: "safe.reloadtest")
        XCTAssertNotNil(application.pluginSession.hosts.existing("safe.reloadtest"))
        XCTAssertEqual(application.enabledPluginInspections().count, 2)
        XCTAssertNotNil(application.pluginCapabilityExecutor)
    }

    // MARK: - Fixtures

    /// Most recently built `GuavaPluginHost`, matching how PluginRuntimeTests
    /// resolves its fixture executable.
    private func pluginHostExecutable() throws -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildRoot = repositoryRoot.appendingPathComponent("Engine/.build", isDirectory: true)
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: buildRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var candidates: Set<URL> = []
        for directory in directories {
            for candidate in [
                directory.appendingPathComponent("GuavaPluginHost"),
                directory.appendingPathComponent("debug").appendingPathComponent("GuavaPluginHost"),
            ] where FileManager.default.isExecutableFile(atPath: candidate.path) {
                candidates.insert(candidate.resolvingSymlinksInPath())
            }
        }
        let newest = candidates.max { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        }
        return try XCTUnwrap(
            newest,
            "GuavaPluginHost is not built; run `swift build --package-path Engine --product GuavaPluginHost` first."
        )
    }

    /// Builds `safe.reloadtest.guavaplugin` from the canonical reader fixture
    /// WAT, mirroring PluginRuntimeTests.makePluginPackage.
    private func makePluginPackage(id: String = "safe.reloadtest",
                                   requires: [PluginRequirement] = []) throws -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let watURL = repositoryRoot
            .appendingPathComponent("Engine/Tests/PluginRuntimeTests/Fixtures/reader.wat")
        let wat = try XCTUnwrap(try? String(contentsOf: watURL, encoding: .utf8),
                                "missing fixture WAT at \(watURL.path)")

        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent(id + ".guavaplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var manifest = GuavaPluginManifest(id: id,
                                           version: 1,
                                           name: "Reload Test",
                                           description: "Editor reload integration fixture",
                                           access: .read,
                                           requires: requires)
        // The capability is offered to the model, so MCP sessions activate the plugin.
        try manifest.contributes.set(AIToolContributionPoint.self, descriptors: [
            AIToolContribution(entryPoint: "inspect", title: "Inspect", description: "Execute one bounded capability.")
        ])
        try JSONEncoder().encode(manifest)
            .write(to: root.appendingPathComponent("plugin.json"))
        try EmbeddedWasmtimeComponentRuntime.compileComponentWAT(wat)
            .write(to: root.appendingPathComponent("component.wasm"))
        let wit = """
        package safe:reader;
        interface capabilities {
          /// Execute one bounded capability.
          record inspect-input {enabled: bool,}
          inspect: func(input: inspect-input) -> string;
        }
        world plugin {
          export capabilities;
        }
        """
        try Data(wit.utf8).write(to: root.appendingPathComponent("capabilities.wit"))
        return root
    }
}
