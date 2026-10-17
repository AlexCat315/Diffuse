// Drive the host's input dispatcher through DevTools, without OS automation.
import Foundation
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("Guava DevTools: " + message + "\n").utf8))
    exit(1)
}

do {

    let arguments = CommandLine.arguments
    guard arguments.count == 4, let port = UInt16(arguments[1]), port > 0,
          ["--click-node", "--input"].contains(arguments[2]) else {
        fail("Usage: swift input-ui-devtools.swift PORT --click-node NODE_ID | --input JSON_OR_@FILE")
    }
    let session = URLSession(configuration: .ephemeral)
    var endpoint = URLComponents(string: "ws://127.0.0.1:\(port)/")!
    if let token = ProcessInfo.processInfo.environment["GUAVA_DEVTOOLS_TOKEN"], !token.isEmpty {
        endpoint.queryItems = [URLQueryItem(name: "token", value: token)]
    }
    let socket = session.webSocketTask(with: endpoint.url!)
    socket.maximumMessageSize = 32 * 1024 * 1024
    let deadline = DispatchWorkItem { socket.cancel(with: .goingAway, reason: nil) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: deadline)
    socket.resume()
    defer { deadline.cancel(); socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }

    func receive() async throws -> [String: Any] {
        let bytes: Data
        switch try await socket.receive() {
        case .data(let data): bytes = data
        case .string(let text): bytes = Data(text.utf8)
        @unknown default: fail("Unknown WebSocket message")
        }
        return try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    }
    var sequence = 0
    @MainActor func request(_ type: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        sequence += 1
        let id = sequence
        let bytes = try JSONSerialization.data(withJSONObject: ["type": type, "id": id, "payload": payload])
        try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
        while true {
            let response = try await receive()
            guard response["id"] as? Int == id else { continue }
            guard response["type"] as? String == type + ".ok" else {
                throw NSError(domain: "GuavaInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(response["payload"] ?? [:])"])
            }
            return response["payload"] as? [String: Any] ?? [:]
        }
    }

    let hello = try await receive()
    let capabilities = (hello["payload"] as? [String: Any])?["capabilities"] as? [String] ?? []
    guard hello["type"] as? String == "hello", capabilities.contains("mirror"), capabilities.contains("diagnostics") else {
        fail("Host must advertise mirror and diagnostics")
    }
    let events: [[String: Any]]
    if arguments[2] == "--click-node" {
        let result = try await request("diagnostics.call", ["name": "query_ui_nodes", "arguments": [
            "node_id": arguments[3], "visible_only": true, "input_enabled_only": true, "limit": 1
        ]])
        guard let items = (result["data"] as? [String: Any])?["items"] as? [[String: Any]], items.count == 1,
              let presentation = items[0]["presentation"] as? [String: Any],
              let frame = presentation["visibleFrame"] as? [String: Double],
              let x = frame["x"], let y = frame["y"], let width = frame["w"], let height = frame["h"],
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else {
            fail("Node has no visible input-enabled hit region; query the current window again")
        }
        events = ["pointerMove", "pointerDown", "pointerUp"].map {
            ["kind": $0, "x": x + width / 2, "y": y + height / 2, "button": 0, "clickCount": 1]
        }
    } else {
        let raw = arguments[3]
        let bytes = try raw.hasPrefix("@") ? Data(contentsOf: URL(fileURLWithPath: String(raw.dropFirst()))) : Data(raw.utf8)
        guard bytes.count <= 262_144,
              let input = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]], (1...256).contains(input.count) else {
            fail("Input must be a JSON array of 1–256 events, at most 256 KiB")
        }
        let kinds = ["pointerMove", "pointerDown", "pointerUp", "wheel", "keyDown", "keyUp", "text"]
        guard input.allSatisfy({ event in
            guard let kind = event["kind"] as? String, kinds.contains(kind) else { return false }
            return event.values.allSatisfy { value in
                if let number = value as? NSNumber { return number.doubleValue.isFinite }
                if let text = value as? String { return text.utf8.count <= 16_384 }
                return value is [String: Any]
            }
        }) else { fail("Input contains an unsupported kind, value or oversized string") }
        events = input
    }
    _ = try await request("mirror.start", ["fps": 1, "quality": 0.5])
    for event in events { _ = try await request("mirror.input", event) }
    // This host-inbox read keeps the connection alive until preceding input
    // deliveries have reached the host. Verify behavior with a subsequent query.
    _ = try await request("diagnostics.call", ["name": "get_diagnostics", "arguments": ["limit": 1]])
    _ = try await request("mirror.stop")
    print("Delivered \(events.count) input events through DevTools; query or capture the resulting UI to verify behavior.")
} catch {
    fail(error.localizedDescription)
}
