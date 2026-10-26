import Dispatch
import Foundation
private import CoveProcess
private import CoveFileSystem

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
let root = environment["COVE_TEST_LSP_ROOT"] ?? ""
let mode = environment["COVE_TEST_LSP_MODE"] ?? "normal"

func rootFile(_ name: String) -> URL {
    URL(fileURLWithPath: root).appendingPathComponent(name)
}

let countFile = rootFile("count")
var count = 1
if let existing = try? String(contentsOf: countFile, encoding: .utf8), let previous = Int(existing) {
    count = previous + 1
}
try? AtomicFile.write(Data(String(count).utf8), to: countFile)

let openedFile = rootFile("opened.jsonl")
FileManager.default.createFile(atPath: openedFile.path, contents: nil)
let opened = try? FileHandle(forWritingTo: openedFile)

var buffer: [UInt8] = []

@MainActor func readByte() -> UInt8? {
    while buffer.isEmpty {
        guard let data = try? PipeRead.available(from: .standardInput), !data.isEmpty else { return nil }
        buffer.append(contentsOf: data)
    }
    return buffer.removeFirst()
}

@MainActor func readLine() -> [UInt8]? {
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

    if method == "test/crash" || (method == "textDocument/hover" && count == 1 && ["crash-first-hover", "environment-first-connection"].contains(mode)) {
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
        if mode == "environment-first-connection" {
            let diagnostics: [[String: Any]] = count == 1 ? [[
                "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]],
                "severity": 1, "message": "Loading the standard library failed",
            ]] : []
            if count == 1 {
                send(["jsonrpc": "2.0", "method": "window/logMessage", "params": ["type": 1, "message": "Loading the standard library failed"]])
            }
            send(["jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                  "params": ["uri": document?["uri"] as? String ?? "", "version": 1, "diagnostics": diagnostics]])
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
        if method == "textDocument/documentSymbol" {
            result = [["name": "value", "kind": 13,
                       "range": ["start": ["line": 0, "character": 4], "end": ["line": 0, "character": 9]]]]
        }
        if method == "textDocument/formatting" { result = [Any]() }
        if method == "textDocument/completion" { result = ["items": [Any](), "isIncomplete": false] }
        if method == "test/burst" {
            for index in 0..<200 {
                send(["jsonrpc": "2.0", "method": "test/notification", "params": index], fragmented: true)
            }
            result = 200
        }
        if method == "test/large" { result = String(repeating: "Swift 🥭\n", count: 80_000) }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }
}
