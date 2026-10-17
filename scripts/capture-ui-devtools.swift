// Capture the actual window draw list through its renderer's DevTools mirror.
import Foundation
import ImageIO
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("Guava DevTools: " + message + "\n").utf8))
    exit(1)
}

do {

    guard CommandLine.arguments.count == 3,
          let port = UInt16(CommandLine.arguments[1]) else {
        fail("Usage: swift capture-ui-devtools.swift PORT OUTPUT.jpg")
    }
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
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

    func send(_ type: String, id: Int, payload: [String: Any] = [:]) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": type, "id": id, "payload": payload])
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func receive() async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .data(let bytes): data = bytes
        case .string(let text): data = Data(text.utf8)
        @unknown default: fail("Unknown WebSocket message")
        }
        let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if (envelope["type"] as? String)?.hasSuffix(".err") == true {
            throw NSError(domain: "GuavaCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(envelope)"])
        }
        return envelope
    }

    let hello = try await receive()
    guard hello["type"] as? String == "hello",
          let capabilities = (hello["payload"] as? [String: Any])?["capabilities"] as? [String],
          capabilities.contains("mirror") else { fail("DevTools mirror is unavailable") }
    try await send("mirror.start", id: 1, payload: ["fps": 1, "quality": 1])
    var capture: [String: Any] = [:]
    while capture.isEmpty {
        let envelope = try await receive()
        if envelope["type"] as? String == "mirror.frame" { capture = envelope["payload"] as! [String: Any] }
    }
    guard let encoded = capture.removeValue(forKey: "jpegBase64") as? String,
          let jpeg = Data(base64Encoded: encoded),
          let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let pixels = image.dataProvider?.data else { fail("Incomplete mirror image") }
    let distinctValues = Set(pixels as Data).count
    guard image.width > 0, image.height > 0, distinctValues > 32 else { fail("Blank mirror image") }
    try jpeg.write(to: output)
    capture["distinctByteValues"] = distinctValues
    try await send("mirror.stop", id: 2)
    while true {
        let envelope = try await receive()
        if envelope["type"] as? String == "mirror.stop.ok" { break }
    }

    let report: [String: Any] = ["hello": hello, "capture": capture,
        "source": "selected-renderer offscreen replay of the actual window draw list",
        "captureIncludesCompositor": false]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.deletingPathExtension().appendingPathExtension("json"))
    print("Captured \(image.width)×\(image.height): \(output.path)")
} catch {
    fail(error.localizedDescription)
}
