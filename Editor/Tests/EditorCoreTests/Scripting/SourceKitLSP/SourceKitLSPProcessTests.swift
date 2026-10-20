import LanguageServerRuntime
import ProcessRuntime
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

private struct LSPProcessFixture {
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

/// Compiles the in-repo Swift language-server fixture once per test process.
///
/// The fixture speaks the same subset of LSP the production client exercises:
/// framed JSON-RPC on stdio, deliberate crash modes, and byte-fragmented bursts.
private enum LSPFixtureServer {
    private static let compiled = Result { try build() }

    static func executable() throws -> URL { try compiled.get() }

    private static func build() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-lsp-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("main.swift")
        let binary = directory.appendingPathComponent("sourcekit-fixture")
        try script.write(to: source, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = try compiler()
        process.arguments = [source.path, "-o", binary.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let log = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LSPFixtureError("failed to compile the language-server fixture:\n\(String(decoding: log, as: UTF8.self))")
        }
        return binary
    }

    private static func compiler() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["GUAVA_SWIFTC"], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        #if os(Windows)
        let name = "swiftc.exe"
        let separator: Character = ";"
        #else
        let name = "swiftc"
        let separator: Character = ":"
        #endif
        for directory in (environment["PATH"] ?? "").split(separator: separator) {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw LSPFixtureError("swiftc is not on PATH; set GUAVA_SWIFTC to a Swift compiler")
    }

    private struct LSPFixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static let script = #"""
import Dispatch
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func crash(_ status: Int32) -> Never {
    FileHandle.standardError.write(Data("fixture unexpected exit\n".utf8))
    exit(status)
}

if CommandLine.arguments.contains("--help") {
    FileHandle.standardOutput.write(Data("test language server\n".utf8))
    exit(0)
}

let environment = ProcessInfo.processInfo.environment
let root = environment["GUAVA_TEST_LSP_ROOT"] ?? ""
let mode = environment["GUAVA_TEST_LSP_MODE"] ?? "normal"

func rootFile(_ name: String) -> URL {
    URL(fileURLWithPath: root).appendingPathComponent(name)
}

let countFile = rootFile("count")
var count = 1
if let existing = try? String(contentsOf: countFile, encoding: .utf8), let previous = Int(existing) {
    count = previous + 1
}
try? String(count).write(to: countFile, atomically: true, encoding: .utf8)

let openedFile = rootFile("opened.jsonl")
FileManager.default.createFile(atPath: openedFile.path, contents: nil)
let opened = try? FileHandle(forWritingTo: openedFile)

var buffer: [UInt8] = []

func readByte() -> UInt8? {
    // FileHandle.read(upToCount:) may wait for the full count or EOF; read(2)
    // returns whatever the client has written so far.
    var chunk = [UInt8](repeating: 0, count: 4096)
    while buffer.isEmpty {
        let count = read(STDIN_FILENO, &chunk, chunk.count)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return nil }
        buffer.append(contentsOf: chunk[..<count])
    }
    return buffer.removeFirst()
}

func readLine() -> [UInt8]? {
    var line: [UInt8] = []
    while let byte = readByte() {
        if byte == 0x0A {
            if line.last == 0x0D { line.removeLast() }
            return line
        }
        line.append(byte)
    }
    return nil
}

func send(_ message: Any, fragmented: Bool = false) {
    guard let body = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { return }
    let packet = Array("Content-Length: \(body.count)\r\n\r\n".utf8) + [UInt8](body)
    if fragmented {
        for byte in packet { FileHandle.standardOutput.write(Data([byte])) }
    } else {
        FileHandle.standardOutput.write(Data(packet))
    }
}

while true {
    var length = 0
    while true {
        guard let header = readLine() else { exit(0) }
        if header.isEmpty { break }
        let text = String(decoding: header, as: UTF8.self).lowercased()
        if text.hasPrefix("content-length:") {
            length = Int(text.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }
    var body: [UInt8] = []
    while body.count < length {
        guard let byte = readByte() else { exit(0) }
        body.append(byte)
    }
    let message = (try? JSONSerialization.jsonObject(with: Data(body), options: [.fragmentsAllowed])) as? [String: Any] ?? [:]
    let method = message["method"] as? String

    if method == "test/crash" || (method == "textDocument/hover" && count == 1 && mode == "crash-first-hover") {
        crash(31)
    }
    if method == "textDocument/didOpen" {
        let document = (message["params"] as? [String: Any])?["textDocument"] as? [String: Any]
        let text = document?["text"] as? String ?? ""
        if let handle = opened, let encoded = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: encoded + Data([0x0A]))
        }
        if mode == "crash-after-open" {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { exit(32) }
        }
    }
    if method == "exit" { exit(0) }
    if let id = message["id"] {
        var result: Any = NSNull()
        if method == "initialize" {
            if mode == "slow-initialize" {
                FileManager.default.createFile(atPath: rootFile("initializing").path, contents: nil)
                Thread.sleep(forTimeInterval: 5)
            }
            result = ["capabilities": [String: Any]()]
        }
        if method == "textDocument/hover" {
            result = ["contents": ["kind": "markdown", "value": "recovered symbol"]]
        }
        if method == "test/burst" {
            for index in 0..<200 {
                send(["jsonrpc": "2.0", "method": "test/notification", "params": index], fragmented: true)
            }
            result = 200
        }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }
}
"""#
}
