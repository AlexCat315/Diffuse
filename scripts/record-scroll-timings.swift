import Foundation
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift scripts/record-scroll-timings.swift PORT OUTPUT.json (1280×720 Demo ScrollView page, --benchmark)")
}
let port = CommandLine.arguments[1]
let output = URL(fileURLWithPath: CommandLine.arguments[2])
// Measure active synthetic point input. Mirror remains enabled at 1fps to
// authorize injection, so readback overhead is included and declared below.
let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/")!)
socket.maximumMessageSize = 32 * 1024 * 1024
socket.resume()
@MainActor
func send(_ type: String, _ id: Int, _ payload: [String: Any] = [:]) async throws {
    let data = try JSONSerialization.data(withJSONObject: ["type": type, "id": id, "payload": payload])
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
}
@MainActor
func receive() async throws -> [String: Any] {
    let m = try await socket.receive()
    let d: Data
    switch m { case .data(let b): d = b; case .string(let s): d = Data(s.utf8); @unknown default: fatalError() }
    return try JSONSerialization.jsonObject(with: d) as! [String: Any]
}
let hello = try await receive()
@MainActor
func findViewport(_ value: Any) -> [String: Any]? {
    if let object = value as? [String: Any] {
        if object["debugName"] as? String == "scroll-lab-viewport" { return object }
        for child in object.values { if let result = findViewport(child) { return result } }
    } else if let array = value as? [Any] {
        for child in array { if let result = findViewport(child) { return result } }
    }
    return nil
}
try await send("tree.subscribe", 4)
var viewport: [String: Any]?
while viewport == nil {
    let response = try await receive()
    if response["id"] as? Int == 4 {
        guard let node = findViewport(response), let frame = node["absoluteFrame"] as? [String: Any] else {
            fatalError("ScrollView story not visible")
        }
        viewport = frame
    }
}
try await send("tree.unsubscribe", 5)
while (try await receive())["id"] as? Int != 5 {}
let x = (viewport!["x"] as! Double) + (viewport!["w"] as! Double) * 0.5
let y = (viewport!["y"] as! Double) + (viewport!["h"] as! Double) * 0.5
try await send("timing.subscribe", 1)
let sender = Task {
    try await send("mirror.start", 2, ["fps": 1, "quality": 0.1])
    try await Task.sleep(for: .milliseconds(300))
    try await send("mirror.input", 3, ["kind": "pointerMove", "x": x, "y": y])
    for cycle in 0..<6 {
        let base = 100 + cycle * 1000
        for i in 0..<120 {
            try await send("mirror.input", base+i, ["kind": "wheel", "x":x, "y":y,
                "deltaY": cycle % 2 == 0 ? -1.25 : 1.25,
                "scroll": ["unit": "points", "device": "continuous", "phase": i == 0 ? "began" : "changed",
                           "momentumPhase": "none", "timestamp": Double(DispatchTime.now().uptimeNanoseconds) / 1e9]])
            try await Task.sleep(for: .milliseconds(16))
        }
        try await send("mirror.input", base+200, ["kind":"wheel", "x":x, "y":y, "deltaY":0,
            "scroll":["unit":"points", "device":"continuous", "phase":"ended", "momentumPhase":"none", "timestamp":0]])
        try await Task.sleep(for: .milliseconds(200))
    }
    try await send("mirror.stop", 9000)
    try await send("timing.unsubscribe", 9999)
}
var frames: [[String: Any]] = []
var enabled = false
var skip = 0
var cycle = -1
var previous: UInt64?
while true {
    let message = try await receive()
    let type = message["type"] as? String ?? ""
    let id = message["id"] as? Int ?? -1
    if type.hasSuffix(".err") { fatalError("\(message)") }
    if type == "timing.unsubscribe.ok" { break }
    if type == "mirror.start.ok" { enabled = false; previous = nil }
    if type == "mirror.input.ok", id >= 100, id < 9000 {
        if (id - 100) % 1000 == 0 { enabled = true; cycle += 1; skip = 3; previous = nil }
        if (id - 100) % 1000 == 200 { enabled = false; previous = nil }
    }
    if type == "timing.frame", enabled, var p = message["payload"] as? [String: Any] {
        if skip > 0 { skip -= 1; continue }
        let now = DispatchTime.now().uptimeNanoseconds
        if let previous { p["arrivalIntervalMs"] = Double(now - previous) / 1e6 }
        previous = now
        p["cycle"] = cycle
        frames.append(p)
    }
}
try await sender.value
socket.cancel(with: .normalClosure, reason: nil)
guard Set(frames.compactMap { $0["cycle"] as? Int }) == Set(0..<6),
      frames.contains(where: { $0["presented"] as? Bool == true }) else {
    fatalError("Missing active or presented frames")
}
@MainActor
func summary(_ key: String) -> [String: Any] {
    let values = frames.compactMap { ($0[key] as? NSNumber)?.doubleValue }.sorted()
    guard !values.isEmpty else { return ["count": 0] }
    return ["count":values.count,"p50":values[Int(Double(values.count-1)*0.5)],"p95":values[Int(Double(values.count-1)*0.95)],"p99":values[Int(Double(values.count-1)*0.99)],"max":values.last!, "above16_67":values.filter{$0 > 16.67}.count,"above33_34":values.filter{$0 > 33.34}.count]
}
let report: [String: Any] = ["hello":hello,"source":"Native demo benchmark mode; six active synthetic point-input streams, 120 packets at 16ms intervals each; first three timing frames discarded per stream. Mirror readback remains enabled at 1fps and its overhead is included. This is not a physical-device trace and is not comparable to the archived post-burst benchmark. Arrival intervals are client receipt intervals, not compositor timestamps.","viewport":viewport!,"sampleCount":frames.count,"presentedFrames":frames.filter { $0["presented"] as? Bool == true }.count,"includesMirrorReadbackOverhead":true,"physicalDeviceTrace":false,"includesGPUCompletionTimestamp":false,"includesCompositorTimestamp":false,"layoutMs":summary("layoutMs"),"drawMs":summary("drawMs"),"presentMs":summary("presentMs"),"totalMs":summary("totalMs"),"arrivalIntervalMs":summary("arrivalIntervalMs"),"frames":frames]
try JSONSerialization.data(withJSONObject: report, options:[.prettyPrinted,.sortedKeys]).write(to:output)
print("Recorded \(frames.count) window frames to \(output.path)")
