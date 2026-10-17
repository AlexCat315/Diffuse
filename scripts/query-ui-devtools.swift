// Invoke the runtime's validated, read-only AI tools against the actual window.
import Foundation
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("Guava DevTools: " + message + "\n").utf8))
    exit(1)
}

do {

    let arguments = CommandLine.arguments
    guard arguments.count >= 3, arguments.count <= 4, let port = UInt16(arguments[1]), port > 0 else {
        fail("Usage: swift query-ui-devtools.swift PORT --list | TOOL [JSON | @FILE]")
    }
    let listing = arguments[2] == "--list"
    var payload: [String: Any] = [:]
    if !listing {
        let raw = arguments.count == 4 ? arguments[3] : "{}"
        let input = try raw.hasPrefix("@") ? Data(contentsOf: URL(fileURLWithPath: String(raw.dropFirst()))) : Data(raw.utf8)
        guard input.count <= 262_144, let object = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
            fail("Tool arguments must be a JSON object of at most 256 KiB")
        }
        payload = ["name": arguments[2], "arguments": object]
    }
    let session = URLSession(configuration: .ephemeral)
    var endpoint = URLComponents(string: "ws://127.0.0.1:\(port)/")!
    if let token = ProcessInfo.processInfo.environment["GUAVA_DEVTOOLS_TOKEN"], !token.isEmpty {
        endpoint.queryItems = [URLQueryItem(name: "token", value: token)]
    }
    let socket = session.webSocketTask(with: endpoint.url!)
    socket.maximumMessageSize = 1_048_576
    let deadline = DispatchWorkItem { socket.cancel(with: .goingAway, reason: nil) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
    socket.resume()
    defer {
        deadline.cancel()
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    func receive() async throws -> [String: Any] {
        let bytes: Data
        switch try await socket.receive() {
        case .data(let data): bytes = data
        case .string(let text): bytes = Data(text.utf8)
        @unknown default: fail("Unknown WebSocket message")
        }
        return try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    }
    let hello = try await receive()
    guard hello["type"] as? String == "hello",
          let capabilities = (hello["payload"] as? [String: Any])?["capabilities"] as? [String],
          capabilities.contains("diagnostics") else { fail("Host does not advertise diagnostic queries") }
    let type = listing ? "diagnostics.tools" : "diagnostics.call"
    let request = try JSONSerialization.data(withJSONObject: ["type": type, "id": 1, "payload": payload])
    try await socket.send(.string(String(decoding: request, as: UTF8.self)))
    while true {
        let response = try await receive()
        guard response["id"] as? Int == 1 else { continue }
        if response["type"] as? String == type + ".err" {
            throw NSError(domain: "GuavaDiagnosticQuery", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(response["payload"] ?? [:])"])
        }
        guard response["type"] as? String == type + ".ok", let value = response["payload"] else {
            fail("Unexpected diagnostic response")
        }
        let output = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        print(String(decoding: output, as: UTF8.self))
        break
    }
} catch {
    fail(error.localizedDescription)
}
