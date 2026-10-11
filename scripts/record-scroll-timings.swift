import Foundation
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift scripts/record-scroll-timings.swift PORT OUTPUT.json (1280×720 Demo ScrollView page, --benchmark)")
}
let port = CommandLine.arguments[1]
let output = URL(fileURLWithPath: CommandLine.arguments[2])
// Input is authorized through a mirror subscription. Measurements begin after
// mirror.stop, with three frames discarded to drain capture and socket queues.
let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/")!)
socket.maximumMessageSize = 32 * 1024 * 1024
socket.resume()
func send(_ type: String, _ id: Int, _ payload: [String: Any] = [:]) async throws {
    let data = try JSONSerialization.data(withJSONObject: ["type": type, "id": id, "payload": payload])
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
}
func receive() async throws -> [String: Any] {
    let m = try await socket.receive()
    let d: Data
    switch m { case .data(let b): d = b; case .string(let s): d = Data(s.utf8); @unknown default: fatalError() }
    return try JSONSerialization.jsonObject(with: d) as! [String: Any]
}
let hello = try await receive()
try await send("timing.subscribe", 1)
let sender = Task {
    try await send("mirror.start", 2, ["fps": 1, "quality": 0.1])
    try await Task.sleep(for: .milliseconds(300))
    try await send("mirror.input", 3, ["kind": "pointerMove", "x": 550, "y": 390])
    for i in 0..<10 {
        try await send("mirror.input", 10+i, ["kind": "wheel", "x":550, "y":390, "deltaY": -1])
        try await Task.sleep(for: .milliseconds(16))
    }
    try await send("mirror.stop", 30)
    try await Task.sleep(for: .seconds(2))
    for cycle in 0..<12 {
        let base = 100 + cycle * 100
        try await send("mirror.start", base, ["fps": 1, "quality": 0.1])
        try await Task.sleep(for: .milliseconds(30))
        for i in 0..<10 {
            try await send("mirror.input", base+1+i, ["kind":"wheel", "x":550, "y":390, "deltaY": cycle % 2 == 0 ? -0.3 : 0.3])
            try await Task.sleep(for: .milliseconds(16))
        }
        try await send("mirror.stop", base+20)
        try await Task.sleep(for: .milliseconds(1500))
    }
    try await send("timing.unsubscribe", 9999)
}
var frames: [[String: Any]] = []
var enabled = false
var skip = 0
var perCycle = 0
var cycle = -1
var previous: UInt64?
while true {
    let message = try await receive()
    let type = message["type"] as? String ?? ""
    let id = message["id"] as? Int ?? -1
    if type.hasSuffix(".err") { fatalError("\(message)") }
    if type == "timing.unsubscribe.ok" { break }
    if type == "mirror.start.ok" { enabled = false; previous = nil }
    if type == "mirror.stop.ok", id >= 100 { enabled = true; cycle += 1; skip = 3; perCycle = 0; previous = nil }
    if type == "timing.frame", enabled, perCycle < 65, var p = message["payload"] as? [String: Any] {
        if skip > 0 { skip -= 1; continue }
        let now = DispatchTime.now().uptimeNanoseconds
        if let previous { p["arrivalIntervalMs"] = Double(now - previous) / 1e6 }
        previous = now
        p["cycle"] = cycle
        frames.append(p); perCycle += 1
    }
}
try await sender.value
socket.cancel(with: .normalClosure, reason: nil)
func summary(_ key: String) -> [String: Any] {
    let values = frames.compactMap { ($0[key] as? NSNumber)?.doubleValue }.sorted()
    guard !values.isEmpty else { return ["count": 0] }
    return ["count":values.count,"p50":values[Int(Double(values.count-1)*0.5)],"p95":values[Int(Double(values.count-1)*0.95)],"p99":values[Int(Double(values.count-1)*0.99)],"max":values.last!, "above16_67":values.filter{$0 > 16.67}.count,"above33_34":values.filter{$0 > 33.34}.count]
}
let report: [String: Any] = ["hello":hello,"source":"Native demo benchmark mode; 12 alternating wheel bursts, first 65 frames after mirror.stop acknowledgement; 3 frames discarded per cycle. Mirror readback disabled in measured windows. Arrival intervals are client receipt intervals, not compositor timestamps.","sampleCount":frames.count,"presentedFrames":frames.filter { $0["presented"] as? Bool == true }.count,"includesGPUCompletionTimestamp":false,"includesCompositorTimestamp":false,"layoutMs":summary("layoutMs"),"drawMs":summary("drawMs"),"presentMs":summary("presentMs"),"totalMs":summary("totalMs"),"arrivalIntervalMs":summary("arrivalIntervalMs"),"frames":frames]
try JSONSerialization.data(withJSONObject: report, options:[.prettyPrinted,.sortedKeys]).write(to:output)
print("Recorded \(frames.count) window frames to \(output.path)")
