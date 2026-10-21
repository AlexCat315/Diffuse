import Foundation
import ScriptRuntime
import Testing
@testable import EditorCore

#if os(macOS) || os(Linux)
@Suite("Swift toolchain activation recovery", .serialized)
@MainActor
struct ToolchainActivationTests {
    @MainActor private final class Events {
        var suspended = false
        var recovered = false
    }

    private struct Fixture {
        let directory: URL
        let previous: URL
        let candidate: URL
        let preferences: URL
        let manager: DynamicScriptManager

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("guava-toolchain-activation-\(UUID().uuidString)")
            previous = directory.appendingPathComponent("Previous")
            candidate = directory.appendingPathComponent("Candidate")
            preferences = directory.appendingPathComponent("Preferences")
            for root in [previous, candidate] {
                let binaries = root.appendingPathComponent("usr/bin")
                let resources = root.appendingPathComponent("usr/lib/swift")
                try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
                let reply = try JSONSerialization.data(withJSONObject: ["compilerVersion": "Swift version 6.4.1",
                    "paths": ["runtimeResourcePath": resources.path]])
                let compiler = binaries.appendingPathComponent("swiftc")
                let script = "#!/bin/sh\nif [ \"$1\" = \"-print-target-info\" ]; then\ncat <<'GUAVA_REPLY'\n"
                    + String(decoding: reply, as: UTF8.self) + "\nGUAVA_REPLY\nfi\nexit 0\n"
                try Data(script.utf8).write(to: compiler)
                let server = binaries.appendingPathComponent("sourcekit-lsp")
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: server)
                for executable in [compiler, server] {
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
                }
            }
            let modules = directory.appendingPathComponent("Modules")
            for name in ["ScriptRuntime", "SceneRuntime"] {
                try FileManager.default.createDirectory(at: modules.appendingPathComponent("\(name).swiftmodule"), withIntermediateDirectories: true)
            }
            var initial = SwiftToolchainPreferences()
            initial.selectedPath = previous.path
            try initial.save(to: preferences)
            manager = DynamicScriptManager(projectDirectory: directory.path, scriptRuntime: ScriptRuntime(),
                engineModulePaths: [modules.path], scriptTrustStorageURL: directory.appendingPathComponent("trust.json"),
                swiftCompilerPath: previous.path)
        }
    }

    @Test("failed plugin activation restores compiler, session and persisted selection")
    func restoresAfterFailure() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let previous = fixture.manager.swiftToolchain
        let events = Events()
        let activation = ScriptToolchainActivation(suspend: { events.suspended = true }, activate: {
            throw SwiftToolchainError.unavailable("mount failed")
        }, recover: { events.recovered = true })
        do {
            try await fixture.manager.configureSwiftToolchain(path: fixture.candidate.path,
                preferencesDirectory: fixture.preferences, activation: activation)
            Issue.record("The simulated mount must fail")
        } catch {}
        #expect(events.suspended && events.recovered)
        #expect(fixture.manager.swiftToolchain == previous)
        #expect(SwiftToolchainPreferences.load(from: fixture.preferences).selectedPath == fixture.previous.path)
    }

    @Test("cancellation after mounting rolls back the activated configuration")
    func restoresAfterCancellation() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let previous = fixture.manager.swiftToolchain
        let events = Events()
        let operation = Task { @MainActor in
            let activation = ScriptToolchainActivation(suspend: { events.suspended = true }, activate: {
                withUnsafeCurrentTask { $0?.cancel() }
            }, recover: { events.recovered = true })
            try await fixture.manager.configureSwiftToolchain(path: fixture.candidate.path,
                preferencesDirectory: fixture.preferences, activation: activation)
        }
        do {
            try await operation.value
            Issue.record("Cancellation must be reported after recovery")
        } catch is CancellationError {} catch { Issue.record(error) }
        #expect(events.suspended && events.recovered)
        #expect(fixture.manager.swiftToolchain == previous)
        #expect(SwiftToolchainPreferences.load(from: fixture.preferences).selectedPath == fixture.previous.path)
    }

    @Test("invalid selection does not stop an existing service or change a manual stop")
    func invalidSelectionPreservesIntent() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try fixture.manager.createScript(name: "Service", source: "let value = 1")
        let model = try ScriptWorkspaceModel(manager: fixture.manager)
        defer { model.shutdown() }
        model.startLanguageService()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.snapshot.languageServiceState == .starting, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let previousState = model.snapshot.languageServiceState
        do {
            try await model.configureSwiftToolchain(path: "/missing/guava-toolchain", preferencesDirectory: fixture.preferences,
                activate: { Issue.record("Invalid toolchains must not reach activation") }, recover: {})
            Issue.record("Invalid toolchains must fail")
        } catch {}
        #expect(model.snapshot.languageServiceState == previousState)
        #expect(!model.snapshot.toolchainActivity.isBusy)
        model.stopLanguageService()
        do {
            try await model.configureSwiftToolchain(path: "/missing/guava-toolchain", preferencesDirectory: fixture.preferences,
                activate: {}, recover: {})
        } catch {}
        #expect(model.snapshot.languageServiceState == .inactive)
    }

    @Test("a successful activation cannot restart a service the user stopped")
    func activationPreservesManualStop() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try fixture.manager.createScript(name: "Service", source: "let value = 1")
        let model = try ScriptWorkspaceModel(manager: fixture.manager)
        defer { model.shutdown() }
        model.stopLanguageService()
        try await model.configureSwiftToolchain(path: fixture.candidate.path, preferencesDirectory: fixture.preferences,
            activate: { model.startLanguageServiceForPluginChange() }, recover: {})
        #expect(model.snapshot.languageServiceState == .inactive)
        #expect(model.snapshot.toolchainActivity == .idle)
        #expect(model.snapshot.swiftToolchain?.rootURL.path == fixture.candidate.path)
    }
}
#endif
