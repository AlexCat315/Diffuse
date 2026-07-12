// Exercises the Apple Network.framework DevServer via a URLSession WebSocket
// client; only runs where Network.framework is available.
#if canImport(Network)
import XCTest
import Foundation
import EngineKernel
@testable import GuavaUIDevTools
@testable import GuavaUIRuntime

/// Integration tests for the mirror.input bridge and state.checkpoint /
/// state.restore round trip. These exercise the full DevServer dispatch
/// path without the GPU side of the FrameTap (which requires a live wgpu
/// context not available in the test process).
final class DevServerInputAndStateTests: XCTestCase {

    @MainActor
    func test_mirror_input_pointer_down_dispatches_to_handler() async throws {
        let tree = NodeTree()
        tree.root = Node()
        let port: UInt16 = UInt16.random(in: 49152...65000)
        let dev = DevTools(
            config: DevToolsConfig(host: "127.0.0.1", port: port,
                                   appTitle: "TestApp", enabled: true),
            tree: tree
        )

        let received = ReceivedEvents()
        dev.inputDelivery = { event in
            Task { @MainActor in received.append(event) }
        }
        try dev.start()
        defer { dev.stop() }

        try await Self.connect(port: port) { task in
            let start = DevToolsEnvelope(type: "mirror.start", id: 1, payload: nil)
            let startData = try JSONEncoder().encode(start)
            try await task.send(.string(String(decoding: startData, as: UTF8.self)))

            let payload: [String: Any] = [
                "kind": "pointerDown",
                "x": 12.5, "y": 34.0,
                "button": 0, "clickCount": 1
            ]
            let env: [String: Any] = ["type": "mirror.input", "payload": payload]
            let data = try JSONSerialization.data(withJSONObject: env)
            try await task.send(.string(String(data: data, encoding: .utf8)!))
        }

        // Allow the @MainActor Task scheduled from the server queue to run.
        for _ in 0..<50 {
            if !received.events.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(received.events.count, 1)
        guard case let .mouseButtonDown(ev) = received.events.first else {
            return XCTFail("expected .mouseButtonDown")
        }
        XCTAssertEqual(ev.x, 12.5)
        XCTAssertEqual(ev.y, 34.0)
        XCTAssertEqual(ev.button, .left)
    }

    @MainActor
    func test_state_checkpoint_round_trip() async throws {
        let tree = NodeTree()
        tree.root = Node()
        let port: UInt16 = UInt16.random(in: 49152...65000)
        let dev = DevTools(
            config: DevToolsConfig(host: "127.0.0.1", port: port,
                                   appTitle: "TestApp", enabled: true),
            tree: tree
        )

        let restored = RestoredSnapshot()
        dev.stateCheckpointProvider = { ["foo": "bar", "scroll": "42"] }
        dev.stateRestoreHandler = { snap in
            Task { @MainActor in restored.snapshot = snap }
        }
        try dev.start()
        defer { dev.stop() }

        let captureBox = CapturedCheckpoint()
        try await Self.connect(port: port) { task in
            let req: [String: Any] = ["type": "state.checkpoint", "id": 7]
            let reqData = try JSONSerialization.data(withJSONObject: req)
            try await task.send(.string(String(data: reqData, encoding: .utf8)!))

            for _ in 0..<10 {
                let m = try await task.receive()
                guard case let .string(s) = m,
                      let data = s.data(using: .utf8) else { continue }
                let env = try JSONDecoder().decode(DevToolsEnvelope.self, from: data)
                if env.type == "state.checkpoint.ok" {
                    if case let .object(dict) = env.payload ?? .null {
                        captureBox.value = dict.compactMapValues { $0.stringValue }
                    }
                    break
                }
            }

            let restoreReq: [String: Any] = [
                "type": "state.restore",
                "payload": captureBox.value
            ]
            let restoreData = try JSONSerialization.data(withJSONObject: restoreReq)
            try await task.send(.string(String(data: restoreData, encoding: .utf8)!))
        }

        for _ in 0..<50 {
            if restored.snapshot != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(captureBox.value, ["foo": "bar", "scroll": "42"])
        XCTAssertEqual(restored.snapshot, ["foo": "bar", "scroll": "42"])
    }

    @MainActor
    func test_disconnect_clears_owned_node_selection() async throws {
        let tree = NodeTree()
        let root = Node()
        tree.root = root
        let port: UInt16 = UInt16.random(in: 49152...65000)
        let dev = DevTools(
            config: DevToolsConfig(host: "127.0.0.1", port: port,
                                   appTitle: "TestApp", enabled: true),
            tree: tree
        )
        let changes = SelectionChanges()
        dev.onSelectionChanged = { changes.count += 1 }
        try dev.start()
        defer { dev.stop() }

        try await Self.connect(port: port) { task in
            let request = DevToolsEnvelope(
                type: "select.node",
                id: 9,
                payload: .object(["id": .string(String(root.id.rawValue))])
            )
            let data = try JSONEncoder().encode(request)
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
            _ = try await task.receive()
        }

        for _ in 0..<50 {
            if dev.selectedNodeID == nil, changes.count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(dev.selectedNodeID)
        XCTAssertGreaterThanOrEqual(changes.count, 2)
    }

    func test_keyboard_input_maps_web_codes_to_scancodes() throws {
        let keyDown = InputBridge.event(from: MirrorInputPayload(
            kind: "keyDown",
            x: nil, y: nil,
            deltaX: nil, deltaY: nil,
            button: nil,
            key: "KeyA",
            keyCode: 65,
            text: nil,
            modifiers: 8,
            clickCount: nil,
            isRepeat: true
        ))
        guard case let .keyDown(down)? = keyDown else {
            return XCTFail("expected keyDown")
        }
        XCTAssertEqual(down.scancode, 4)
        XCTAssertEqual(down.keycode, 65)
        XCTAssertTrue(down.modifiers.hasGui)
        XCTAssertTrue(down.isRepeat)

        let keyUp = InputBridge.event(from: MirrorInputPayload(
            kind: "keyUp",
            x: nil, y: nil,
            deltaX: nil, deltaY: nil,
            button: nil,
            key: "ArrowLeft",
            keyCode: 37,
            text: nil,
            modifiers: 0,
            clickCount: nil,
            isRepeat: false
        ))
        guard case let .keyUp(up)? = keyUp else {
            return XCTFail("expected keyUp")
        }
        XCTAssertEqual(up.scancode, 80)
        XCTAssertEqual(up.keycode, 37)
    }

    func test_keyboard_input_maps_common_editing_codes() throws {
        XCTAssertEqual(Self.scancode(for: "Slash"), 56)
        XCTAssertEqual(Self.scancode(for: "F5"), 62)
        XCTAssertEqual(Self.scancode(for: "PageDown"), 78)
        XCTAssertEqual(Self.scancode(for: "Numpad0"), 98)
        XCTAssertEqual(Self.scancode(for: "NumpadAdd"), 87)
        XCTAssertNil(InputBridge.event(from: MirrorInputPayload(
            kind: "keyDown",
            x: nil, y: nil,
            deltaX: nil, deltaY: nil,
            button: nil,
            key: "UnknownKey",
            keyCode: 0,
            text: nil,
            modifiers: nil,
            clickCount: nil,
            isRepeat: nil
        )))
    }

    // MARK: - Helpers

    private static func scancode(for webCode: String) -> UInt32? {
        let event = InputBridge.event(from: MirrorInputPayload(
            kind: "keyDown",
            x: nil, y: nil,
            deltaX: nil, deltaY: nil,
            button: nil,
            key: webCode,
            keyCode: 0,
            text: nil,
            modifiers: nil,
            clickCount: nil,
            isRepeat: nil
        ))
        guard case let .keyDown(key)? = event else { return nil }
        return key.scancode
    }

    /// Open a websocket, wait for `hello`, run the body, then close.
    private static func connect(port: UInt16,
                                _ body: @Sendable (URLSessionWebSocketTask) async throws -> Void) async throws {
        let url = URL(string: "ws://127.0.0.1:\(port)/")!
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        // Drain the unsolicited hello frame.
        _ = try await task.receive()
        try await body(task)
    }

    @MainActor
    private final class ReceivedEvents {
        var events: [InputEvent] = []
        func append(_ e: InputEvent) { events.append(e) }
    }

    @MainActor
    private final class RestoredSnapshot {
        var snapshot: [String: String]?
    }

    @MainActor
    private final class SelectionChanges {
        var count = 0
    }

    private final class CapturedCheckpoint: @unchecked Sendable {
        var value: [String: String] = [:]
    }
}
#endif
