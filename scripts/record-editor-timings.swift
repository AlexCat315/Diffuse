// Observe the real window submission path without enabling mirror readbacks.
import Foundation

guard CommandLine.arguments.count == 5,
      let port = UInt16(CommandLine.arguments[1]),
      let count = Int(CommandLine.arguments[3]), count > 0,
      let warmup = Int(CommandLine.arguments[4]), warmup >= 0 else {
    fatalError("Usage: swift record-editor-timings.swift PORT OUTPUT.json FRAMES WARMUP")
}
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let session = URLSession(configuration: .ephemeral)
let socket = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/")!)
socket.resume()
defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }

func send(_ type: String, id: Int) async throws {
    let data = try JSONSerialization.data(withJSONObject: ["type": type, "id": id])
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
}
func receive() async throws -> [String: Any] {
    let message = try await socket.receive()
    let data: Data
    switch message {
    case .data(let bytes): data = bytes
    case .string(let value): data = Data(value.utf8)
    @unknown default: fatalError("Unknown WebSocket message")
    }
    let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    if (envelope["type"] as? String)?.hasSuffix(".err") == true { fatalError("\(envelope)") }
    return envelope
}
let hello = try await receive()
guard hello["type"] as? String == "hello",
      let capabilities = (hello["payload"] as? [String: Any])?["capabilities"] as? [String],
      capabilities.contains("timing") else { fatalError("DevTools timing is unavailable") }
try await send("timing.subscribe", id: 1)
var skipped = 0
var frames: [[String: Any]] = []
var started: UInt64 = 0
while frames.count < count {
    let envelope = try await receive()
    guard envelope["type"] as? String == "timing.frame",
          let payload = envelope["payload"] as? [String: Any] else { continue }
    if skipped < warmup { skipped += 1; continue }
    if frames.isEmpty { started = DispatchTime.now().uptimeNanoseconds }
    frames.append(payload)
}
let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
try await send("timing.unsubscribe", id: 2)
while true {
    if try await receive()["type"] as? String == "timing.unsubscribe.ok" { break }
}
func summary(_ key: String) -> [String: Any] {
    let values = frames.map { ($0[key] as! NSNumber).doubleValue }.sorted()
    return ["p50": values[Int(ceil(Double(count) * 0.5)) - 1],
            "p95": values[Int(ceil(Double(count) * 0.95)) - 1],
            "minimum": values.first!, "maximum": values.last!]
}
let presented = frames.filter { $0["presented"] as? Bool == true }.count
let report: [String: Any] = ["hello": hello, "warmup": warmup, "sampleCount": count,
    "source": "AppRuntime real-window layout, draw-list construction, submission and present calls; mirror disabled",
    "includesGPUCompletionTimestamp": false, "includesCompositorTimestamp": false,
    "streamElapsedSeconds": elapsed, "streamFramesPerSecond": Double(count - 1) / elapsed,
    "presentedFrames": presented, "unpresentedFrames": count - presented,
    "layoutMs": summary("layoutMs"), "drawMs": summary("drawMs"),
    "presentMs": summary("presentMs"), "totalMs": summary("totalMs"),
    "nodeCount": summary("nodeCount"), "batchCount": summary("batchCount"), "frames": frames]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
guard presented == count else {
    FileHandle.standardError.write(Data("Only \(presented) / \(count) window frames were submitted/presented; benchmark rejected. Report: \(output.path)\n".utf8))
    exit(1)
}
print("Recorded \(count) presented window frames: \(output.path)")
