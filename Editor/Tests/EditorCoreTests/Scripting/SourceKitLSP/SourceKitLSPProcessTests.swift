import LanguageServerRuntime
internal import GuavaProcess
import Foundation
import GuavaUICompose
import Testing
@testable import EditorCore

@Suite("SourceKit-LSP process lifecycle", .serialized)
struct SourceKitLSPProcessTests {
    @Test("Ordered pipe reads preserve fragmented bursts and intentional restarts")
    func orderedMessagesAndRestart() async throws {
        let fixture = try LSPProcessFixture()
        defer { fixture.remove() }
        let failures = LSPEventLog<LSPFailure>()
        let notifications = LSPEventLog<LSPNotification>()
        let client = fixture.client()
        for _ in 0..<4 {
            try await client.start(notificationHandler: { notifications.append($0) }, onFailure: { failures.append($0) })
            try await client.initialize()
            let result = try await client.request("test/burst", timeout: .seconds(3))
            #expect(String(decoding: try #require(result), as: UTF8.self) == "200")
            #expect(await client.isRunning)
            await client.shutdown()
            #expect(!(await client.isRunning))
        }
        #expect(notifications.values.count == 800)
        #expect(failures.values.isEmpty)
        let order = try notifications.values.map { item in
            try #require((try JSONSerialization.jsonObject(with: item.params, options: .fragmentsAllowed)) as? Int)
        }
        #expect(order == Array(repeating: Array(0..<200), count: 4).flatMap { $0 })
    }

    @Test("An unexpected exit reports once even without pending requests")
    func unsolicitedExit() async throws {
        let fixture = try LSPProcessFixture()
        defer { fixture.remove() }
        let failures = LSPEventLog<LSPFailure>()
        let client = fixture.client()
        try await client.start(onFailure: { failures.append($0) })
        try await client.initialize()
        try await client.notify("test/crash")
        try await waitUntil { failures.values.count == 1 }
        #expect(!(await client.isRunning))
        await client.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(failures.values.count == 1)
        #expect(!failures.values[0].message.isEmpty)
        await #expect(throws: LSPClientError.notRunning) {
            try await client.request("textDocument/hover")
        }
    }

    @Test("Recovery opens the latest unsaved root and revisions without rewriting disk")
    func latestRootRecovery() async throws {
        let fixture = try LSPProcessFixture(mode: "crash-first-hover")
        defer { fixture.remove() }
        let events = LSPEventLog<ScriptLanguageServiceUpdate>()
        let support = fixture.support()
        let file = DynamicScriptManager.ScriptFile(url: fixture.root.appendingPathComponent("Scripts/Demo.swift"))
        try await support.start(sources: [.init(file: file, text: "let value = 1")], onDiagnostics: { _ in },
                                onStateChange: { events.append($0) })
        let shadow = try #require(await support.shadowURI(for: file.identifier))
        do { _ = try await support.hover(scriptID: file.identifier, at: .init(line: 0, character: 4)) }
        catch { /* The first server deliberately exits while answering. */ }
        try await waitUntil { events.values.contains { if case .unavailable = $0.state { return true }; return false } }
        try await support.update(scriptID: file.identifier, text: "let value = 42 // unsaved 😀", revision: 2)
        try await waitUntil { await support.isReady }
        let hover = try await support.hover(scriptID: file.identifier, at: .init(line: 0, character: 4))
        #expect(hover?.contents.contains("recovered") == true)
        #expect(try String(contentsOf: shadow, encoding: .utf8) == "let value = 1")
        let opened = try fixture.openedDocuments()
        #expect(opened.last == "let value = 42 // unsaved 😀")
        #expect(events.values.map(\.revision) == events.values.map(\.revision).sorted())
        await support.stop()
        #expect(events.values.last?.state == .inactive)
    }

    @Test("Stopping during backoff cancels reconnection")
    func stopCancelsRecovery() async throws {
        let fixture = try LSPProcessFixture(mode: "crash-first-hover")
        defer { fixture.remove() }
        let events = LSPEventLog<ScriptLanguageServiceUpdate>()
        let support = fixture.support()
        let file = DynamicScriptManager.ScriptFile(url: fixture.root.appendingPathComponent("Scripts/Demo.swift"))
        try await support.start(sources: [.init(file: file, text: "let value = 1")], onDiagnostics: { _ in },
                                onStateChange: { events.append($0) })
        _ = try? await support.hover(scriptID: file.identifier, at: .init(line: 0, character: 4))
        try await waitUntil { events.values.contains { if case .unavailable = $0.state { return true }; return false } }
        await support.stop()
        try await Task.sleep(for: .milliseconds(800))
        #expect(try fixture.launchCount() == 1)
        #expect(!(await support.isReady))
        #expect(events.values.last?.state == .inactive)
    }

    @Test("syntax replies keep analysis checking until a semantic result is available")
    func syntaxDoesNotConfirmHealth() async throws {
        let fixture = try LSPProcessFixture()
        defer { fixture.remove() }
        let support = fixture.support()
        let file = DynamicScriptManager.ScriptFile(url: fixture.root.appendingPathComponent("Scripts/Demo.swift"))
        try await support.start(sources: [.init(file: file, text: "let value = 1")], onDiagnostics: { _ in })
        _ = try await support.documentSymbols(scriptID: file.identifier)
        _ = try await support.formatting(scriptID: file.identifier)
        _ = try await support.completion(scriptID: file.identifier, at: .init(line: 0, character: 4))
        #expect((await support.languageServiceDetails()).health == .checking)
        _ = try await support.hover(scriptID: file.identifier, at: .init(line: 0, character: 4))
        #expect((await support.languageServiceDetails()).health == .healthy)
        await support.stop()
    }

    @Test("automatic recovery clears environment failures owned by the old connection")
    func recoveryClearsEnvironmentFailure() async throws {
        let fixture = try LSPProcessFixture(mode: "environment-first-connection")
        defer { fixture.remove() }
        let support = fixture.support()
        let file = DynamicScriptManager.ScriptFile(url: fixture.root.appendingPathComponent("Scripts/Demo.swift"))
        try await support.start(sources: [.init(file: file, text: "let value = 1")], onDiagnostics: { _ in })
        try await waitUntil {
            if case .degraded = (await support.languageServiceDetails()).health { return true }
            return false
        }
        _ = try? await support.hover(scriptID: file.identifier, at: .init(line: 0, character: 4))
        try await waitUntil {
            let ready = await support.isReady
            return try fixture.launchCount() == 2 && ready
        }
        #expect((await support.languageServiceDetails()).health == .checking)
        _ = try await support.hover(scriptID: file.identifier, at: .init(line: 0, character: 4))
        #expect((await support.languageServiceDetails()).health == .healthy)
        #expect((await support.languageServiceDetails()).logs.contains { $0.message.contains("standard library") })
        await support.stop()
    }

    @Test("Repeated crashes stop after three automatic recovery attempts")
    func boundedRecovery() async throws {
        let fixture = try LSPProcessFixture(mode: "crash-after-open")
        defer { fixture.remove() }
        let events = LSPEventLog<ScriptLanguageServiceUpdate>()
        let support = fixture.support()
        let file = DynamicScriptManager.ScriptFile(url: fixture.root.appendingPathComponent("Scripts/Demo.swift"))
        try await support.start(sources: [.init(file: file, text: "let value = 1")], onDiagnostics: { _ in },
                                onStateChange: { events.append($0) })
        try await waitUntil(timeout: .seconds(12)) {
            try fixture.launchCount() == 4 && events.values.filter {
                if case .unavailable = $0.state { return true }; return false
            }.count >= 4
        }
        try await Task.sleep(for: .milliseconds(800))
        #expect(try fixture.launchCount() == 4)
        #expect(!(await support.isReady))
        try await support.restart(sources: [.init(file: file, text: "let value = 99 // manual retry")])
        #expect(await support.isReady)
        #expect(try fixture.launchCount() == 5)
        // Sending didOpen does not wait for the fixture process to consume it.
        try await waitUntil {
            try fixture.openedDocuments().last == "let value = 99 // manual retry"
        }
        #expect(try fixture.openedDocuments().last == "let value = 99 // manual retry")
        await support.stop()
    }

    @Test("Stop interrupts initialize without waiting for its response timeout")
    func stopDuringInitialize() async throws {
        let fixture = try LSPProcessFixture(mode: "slow-initialize")
        defer { fixture.remove() }
        let support = fixture.support()
        let file = DynamicScriptManager.ScriptFile(url: fixture.root.appendingPathComponent("Scripts/Demo.swift"))
        let task = Task {
            try await support.start(sources: [.init(file: file, text: "let value = 1")], onDiagnostics: { _ in })
        }
        try await waitUntil { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("initializing").path) }
        let start = ContinuousClock.now
        await support.stop()
        #expect(start.duration(to: .now) < .seconds(1))
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!(await support.isReady))
        try await Task.sleep(for: .milliseconds(600))
        #expect(try fixture.launchCount() == 1)
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Process lifecycle condition timed out")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private final class LSPEventLog<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Value] = []
    func append(_ value: Value) { lock.withLock { entries.append(value) } }
    var values: [Value] { lock.withLock { entries } }
}

struct LSPProcessFixture {
    let root: URL
    let executable: URL
    let mode: String
    init(mode: String = "normal") throws {
        self.mode = mode
        root = FileManager.default.temporaryDirectory.appendingPathComponent("guava-lsp-process-\(UUID().uuidString)")
        executable = try LSPFixtureServer.executable()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    var environment: [String: String] { ["GUAVA_TEST_LSP_ROOT": root.path, "GUAVA_TEST_LSP_MODE": mode] }
    func client() -> LSPClient {
        var command = ProcessCommand(executable: executable, directory: root)
        command.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
        return .init(configuration: LanguageServerConfiguration(command: command, workspace: root))
    }
    func support() -> ScriptLanguageSupport {
        .init(scriptsDirectoryURL: root.appendingPathComponent("Scripts"), engineModulePaths: [], executableURL: executable, environment: environment)
    }
    func launchCount() throws -> Int {
        Int(try String(contentsOf: root.appendingPathComponent("count"), encoding: .utf8)) ?? 0
    }
    func openedDocuments() throws -> [String] {
        let data = try String(contentsOf: root.appendingPathComponent("opened.jsonl"), encoding: .utf8)
        return try data.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) as? String)
        }
    }
}

/// Built with the package so test execution never launches a compiler or inherits its pipes.
private enum LSPFixtureServer {
    static func executable() throws -> URL {
        #if os(Windows)
        let name = "LanguageServerFixture.exe"
        #else
        let name = "LanguageServerFixture"
        #endif
        let binaryDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [binaryDirectory.appendingPathComponent(name),
            Bundle(for: LSPFixtureBundle.self).bundleURL.deletingLastPathComponent().appendingPathComponent(name)]
        return try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
    }
}

private final class LSPFixtureBundle: NSObject {}
