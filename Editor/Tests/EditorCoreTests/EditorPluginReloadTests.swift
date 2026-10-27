import CapabilityRuntime
@testable import EditorCore
import Foundation
import PluginRuntime
import XCTest

/// End-to-end reload coverage: a real `DiffusePluginHost` process, a Bun package
/// with static contracts, and the Editor's mount / reload /
/// stale-rejection paths.
@MainActor
final class EditorPluginReloadTests: XCTestCase {
    func testReloadRemountsUnchangedPackageAndSurfacesChangedPackage() async throws {
        var step = "locate host" { didSet { pluginE2ELog("step: \(step)") } }
        pluginE2ELog("step: \(step)")
        do {
            let host = try pluginHostExecutable()
            step = "build package"
            let package = try makePluginPackage()
            defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }

            let project = FileManager.default.temporaryDirectory
                .appendingPathComponent("cove-plugin-reload-\(UUID().uuidString)", isDirectory: true)
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
            _ = try await withTimeout(step: step) {
                try await application.enablePlugin(at: package, authorization: authorization)
            }
            XCTAssertTrue(application.pluginSession.manager.activeBindings.isEmpty)
            let opened = try await withTimeout(step: "open capability session") {
                await application.handleMCPMessage(Data(
                    #"{"action":"open_capability_session","session_id":"4394C8F4-96BF-48C7-880B-40B83D787DFC"}"#.utf8))
            }
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: opened) as? [String: Any])
            XCTAssertEqual(response["ok"] as? Bool, true, String(describing: response))
            XCTAssertEqual(application.enabledPluginInspections().map(\.manifest.id),
                           ["safe.reloadtest"])
            let generationBefore = try XCTUnwrap(
                application.pluginSession.manager.activeBindings["safe.reloadtest"]?.hostGeneration
            )

            // Byte-identical package: one-step remount on the same host generation.
            step = "reload"
            try await withTimeout(step: step) {
                try await application.reloadPlugin(id: "safe.reloadtest")
            }
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
                try await withTimeout(step: step) {
                    try await application.reloadPlugin(id: "safe.reloadtest")
                }
                XCTFail("expected a stale-authorization rejection")
            } catch let error as PluginE2EStepTimeout {
                throw error
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
            try await withTimeout(step: step) {
                await application.reloadPluginFromManagement(id: "safe.reloadtest")
            }
            XCTAssertEqual(application.store.state.assistant.pluginManagement.candidate?.id,
                           "safe.reloadtest")
            XCTAssertEqual(application.store.state.assistant.pluginManagement.phase,
                           .awaitingAuthorization)

            step = "approve replacement build"
            application.pluginSession.editor.installations = PluginInstallations(root: package.deletingLastPathComponent().appendingPathComponent("installed-plugins-" + UUID().uuidString))
            defer { if let root = application.pluginSession.editor.installations?.root { try? FileManager.default.removeItem(at: root) } }
            try await withTimeout(step: step) {
                await application.authorizeAndEnableInspectedPlugin()
            }
            XCTAssertEqual(application.store.state.assistant.pluginManagement.phase, .idle)
            XCTAssertEqual(application.enabledPluginInspections().first?.manifest.version, 2)

            step = "disable"
            try await withTimeout(step: step) {
                try await application.disablePlugin(id: "safe.reloadtest")
            }
            XCTAssertTrue(application.enabledPluginInspections().isEmpty)
        } catch {
            XCTFail("failed at step '\(step)': \(error)")
        }
    }

    func testDependenciesProtectDisableAndReloadRollsBackAfterGenerationLoss() async throws {
        var step = "locate host" { didSet { pluginE2ELog("step: \(step)") } }
        pluginE2ELog("step: \(step)")
        let host = try pluginHostExecutable()
        step = "build packages"
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
        step = "create application"
        let application = try EditorApplication(projectDirectory: project.path, seedPreviewScene: false,
                                                trustedPluginHostExecutableURL: host)
        defer { application.shutdown() }
        step = "authorize dependent"
        let dependentAuthorization = try application.makePluginAuthorization(
            afterUserApprovalOf: application.inspectPlugin(at: dependent))
        step = "enable dependent without provider"
        do {
            _ = try await withTimeout(step: step) {
                try await application.enablePlugin(at: dependent, authorization: dependentAuthorization)
            }
            XCTFail("Missing capability dependency must fail")
        } catch let error as PluginE2EStepTimeout {
            throw error
        } catch is UnmetPluginRequirements {}
        XCTAssertTrue(application.enabledPluginInspections().isEmpty)
        step = "enable provider"
        let providerAuthorization = try application.makePluginAuthorization(
            afterUserApprovalOf: application.inspectPlugin(at: provider))
        _ = try await withTimeout(step: step) {
            try await application.enablePlugin(at: provider, authorization: providerAuthorization)
        }
        try await withTimeout(step: "activate provider") {
            try await application.activatePlugins(event: "onAITool:safe.reloadtest.inspect")
        }
        step = "enable dependent"
        _ = try await withTimeout(step: step) {
            try await application.enablePlugin(at: dependent, authorization: dependentAuthorization)
        }
        try await withTimeout(step: "activate dependent") {
            try await application.activatePlugins(event: "onAITool:safe.dependent.inspect")
        }
        step = "reload both concurrently"
        let first = Task { @MainActor in
            try await withTimeout(step: "reload provider") {
                try await application.reloadPlugin(id: "safe.reloadtest")
            }
        }
        let second = Task { @MainActor in
            try await withTimeout(step: "reload dependent") {
                try await application.reloadPlugin(id: "safe.dependent")
            }
        }
        try await first.value
        try await second.value
        XCTAssertEqual(application.enabledPluginInspections().count, 2)
        // Each plugin owns its process. Dropping the provider's host stops only
        // that plugin; its dependent keeps the process that loaded it.
        step = "drop provider host"
        application.pluginSession.hosts.discard("safe.reloadtest")
        XCTAssertNil(application.pluginSession.hosts.existing("safe.reloadtest"))
        XCTAssertNotNil(application.pluginSession.hosts.existing("safe.dependent"))
        step = "reload after generation loss"
        try await withTimeout(step: step) {
            try await application.reloadPlugin(id: "safe.reloadtest")
        }
        XCTAssertNotNil(application.pluginSession.hosts.existing("safe.reloadtest"))
        XCTAssertEqual(application.enabledPluginInspections().count, 2)
        XCTAssertNotNil(application.pluginCapabilityExecutor)
        try await application.disablePlugin(id: "safe.reloadtest")
        XCTAssertTrue(application.enabledPluginInspections().isEmpty)
        XCTAssertTrue(application.pluginSession.hosts.pluginIDs.isEmpty)
    }

    // MARK: - Fixtures

    /// Most recently built `DiffusePluginHost`, matching how PluginRuntimeTests
    /// resolves its fixture executable.
    private func pluginHostExecutable() throws -> URL {
        try XCTUnwrap(EditorPluginHostLocator.resolve(),
                      "DiffusePluginHost is not built; run `cove test Editor --build-only` first.")

    }

    /// Builds a TypeScript runtime fixture with a public static input contract.
    private func makePluginPackage(id: String = "safe.reloadtest",
                                   requires: [PluginRequirement] = []) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent(id + ".coveplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var manifest = CovePluginManifest(id: id,
                                           version: 1,
                                           name: "Reload Test",
                                           description: "Editor reload integration fixture",
                                           access: .read,
                                           requires: requires)
        manifest.runtime = .init()
        // The capability is offered to the model, so MCP sessions activate the plugin.
        try manifest.contributes.set(AIToolContributionPoint.self, descriptors: [
            AIToolContribution(entryPoint: "inspect", title: "Inspect", description: "Execute one bounded capability.")
        ])
        try JSONEncoder().encode(manifest)
            .write(to: root.appendingPathComponent("plugin.json"))
        try Data("export default {capabilities:{inspect:{input:{record:{enabled:'bool'}},run:()=>({summary:'bounded'})}}}".utf8)
            .write(to: root.appendingPathComponent("plugin.js"))
        try Data(#"{"version":1,"entries":[{"name":"inspect","description":"Execute one bounded capability.","input":{"record":{"enabled":"bool"}}}]}"#.utf8)
            .write(to: root.appendingPathComponent("capabilities.json"))
        return root
    }
}

// MARK: - Step instrumentation and timeouts

/// The e2e tests spawn a real plugin host; a wedged host must surface as a
/// fast, step-labelled failure instead of silently consuming the CI step
/// timeout (Windows pipe reads can otherwise block a request forever).
private struct PluginE2EStepTimeout: Error, CustomStringConvertible {
    let step: String
    let seconds: UInt64

    var description: String { "timed out after \(seconds)s at step '\(step)'" }
}

/// Resume-once box for the timeout race. The loser of the race (the wedged
/// operation, once it eventually unwinds) may still try to deliver its result
/// long after the winner resumed the test, and the winner may finish before
/// the test even starts waiting.
private final class PluginE2EResumeBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<T, any Error>, Never>?
    private var pending: Result<T, any Error>?
    private var resumed = false

    func wait() async -> Result<T, any Error> {
        await withCheckedContinuation { continuation in
            let immediate: Result<T, any Error>? = lock.withLock {
                if let pending {
                    self.pending = nil
                    return pending
                }
                self.continuation = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    @discardableResult
    func resume(_ result: Result<T, any Error>) -> Bool {
        let target: CheckedContinuation<Result<T, any Error>, Never>? = lock.withLock {
            guard !resumed else { return nil }
            resumed = true
            if let continuation {
                self.continuation = nil
                return continuation
            }
            pending = result
            return nil
        }
        guard let target else { return false }
        target.resume(returning: result)
        return true
    }
}

private func withTimeout<T: Sendable>(
    _ seconds: UInt64 = 90,
    step: String,
    _ operation: sending @escaping @isolated(any) () async throws -> T
) async throws -> T {
    let box = PluginE2EResumeBox<T>()
    // The operation inherits the current actor so plugin state behaves exactly
    // as an unwrapped await. The watchdog is detached so it still fires when
    // the operation wedged an actor's executor behind a blocking pipe call.
    let work = Task {
        do { _ = box.resume(.success(try await operation())) }
        catch { _ = box.resume(.failure(error)) }
    }
    let watchdog = Task.detached {
        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        work.cancel()
        _ = box.resume(.failure(PluginE2EStepTimeout(step: step, seconds: seconds)))
    }
    let result = await box.wait()
    watchdog.cancel()
    return try result.get()
}

private func pluginE2ELog(_ message: String) {
    let timestamp = pluginE2ETimeFormatter.string(from: Date())
    FileHandle.standardError.write(Data("[plugin-e2e \(timestamp)] \(message)\n".utf8))
}

private let pluginE2ETimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()
