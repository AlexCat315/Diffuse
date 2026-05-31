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

    // MARK: - Helpers

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

    private final class CapturedCheckpoint: @unchecked Sendable {
        var value: [String: String] = [:]
    }
}
#endif
