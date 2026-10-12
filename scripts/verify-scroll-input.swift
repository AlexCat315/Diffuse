// Real Demo ViewGraph checks using synthetic phased input. Not a physical
// trackpad recording, compositor timing or a visual smoothness measurement.
import Foundation

guard CommandLine.arguments.count == 3 else { fatalError("Usage: swift scripts/verify-scroll-input.swift PORT OUTPUT.json (Demo --component scrollview)") }
let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(CommandLine.arguments[1])/")!)
socket.maximumMessageSize = 32 * 1024 * 1024
socket.resume()
defer { socket.cancel(with: .normalClosure, reason: nil) }
var serial = 0
@MainActor
func receive() async throws -> [String: Any] {
    let message = try await socket.receive()
    let data: Data
    switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: fatalError() }
    let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    if (result["type"] as? String)?.hasSuffix(".err") == true { fatalError("\(result)") }
    return result
}
@MainActor
func request(_ type: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
    serial += 1
    let id = serial
    let data = try JSONSerialization.data(withJSONObject: ["type": type, "id": id, "payload": payload])
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    while true { let response = try await receive(); if response["id"] as? Int == id { return response } }
}
@MainActor
func find(_ value: Any) -> [String: Any]? {
    if let object = value as? [String: Any] {
        if object["debugName"] as? String == "scroll-lab-viewport" { return object }
        for child in object.values { if let result = find(child) { return result } }
    } else if let array = value as? [Any] {
        for child in array { if let result = find(child) { return result } }
    }
    return nil
}
@MainActor
func viewport() async throws -> [String: Any] {
    let response = try await request("tree.subscribe")
    guard let node = find(response) else { fatalError("ScrollView story not visible") }
    return node
}
@MainActor
func offset() async throws -> Double {
    let node = try await viewport()
    return (node["contentOffset"] as! [String: Any])["y"] as! Double
}
let hello = try await receive()
_ = try await request("tree.subscribe")
_ = try await request("mirror.start", ["fps": 1, "quality": 0.1])
let node = try await viewport()
let frame = node["absoluteFrame"] as! [String: Any]
let x = (frame["x"] as! Double) + (frame["w"] as! Double) * 0.5
let y = (frame["y"] as! Double) + (frame["h"] as! Double) * 0.5
@MainActor
func wheel(_ delta: Double, phase: String = "none", momentum: String = "none") async throws {
    _ = try await request("mirror.input", ["kind": "wheel", "x": x, "y": y, "deltaY": delta,
        "scroll": ["unit": "points", "device": "continuous", "phase": phase,
                   "momentumPhase": momentum, "timestamp": Double(DispatchTime.now().uptimeNanoseconds) / 1e9]])
    try await Task.sleep(for: .milliseconds(35))
}
var checks: [[String: Any]] = []
@MainActor
func check(_ name: String, actual: Double, expected: Double) {
    let passed = abs(actual - expected) < 0.001
    checks.append(["case": name, "actual": actual, "expected": expected, "passed": passed])
    guard passed else { fatalError("\(name): \(actual), expected \(expected)") }
}
try await wheel(100_000, phase: "began") // Clamp to start.
try await wheel(-12.5, phase: "began")
var expected = 12.5
check("precise points are not multiplied by line step", actual: try await offset(), expected: expected)
for (delta, gap) in [(-8.25, 16), (-4.5, 130), (-2.25, 150), (-0.5, 16)] {
    try await Task.sleep(for: .milliseconds(gap))
    try await wheel(delta, phase: "changed")
    expected -= delta
    check("uneven input gap \(gap)ms", actual: try await offset(), expected: expected)
}
try await wheel(0, phase: "ended")
for delta in [-3.0, -1.5, -0.25] { try await wheel(delta, momentum: "changed"); expected -= delta }
try await wheel(0, momentum: "ended")
try await Task.sleep(for: .seconds(1))
check("OS momentum ends without a second fling", actual: try await offset(), expected: expected)
try await wheel(-6, phase: "began"); expected += 6
try await wheel(0, phase: "ended")
try await wheel(-2, momentum: "began"); expected += 2
_ = try await request("mirror.input", ["kind": "pointerDown", "x": x, "y": y, "button": 0])
_ = try await request("mirror.input", ["kind": "pointerUp", "x": x, "y": y, "button": 0])
try await wheel(-10, momentum: "changed")
check("click suppresses remaining system momentum", actual: try await offset(), expected: expected)
try await wheel(2.25, phase: "began"); expected -= 2.25
check("new reverse gesture resumes immediately", actual: try await offset(), expected: expected)
_ = try await request("mirror.stop")
_ = try await request("tree.unsubscribe")
let report: [String: Any] = ["hello": hello, "source": "Native Demo + synthetic DevTools phased input + actual ViewGraph offsets", "physicalDeviceTrace": false, "includesCompositorTiming": false, "viewport": frame, "checks": checks]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("Passed \(checks.count) native scroll input checks")
