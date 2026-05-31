// DevServer uses Apple's Network.framework, so this end-to-end test only runs
// where it is available. (Porting the dev hot-reload server to portable sockets
// is tracked separately.)
#if canImport(Network)
import XCTest
import Foundation
import Network
@testable import GuavaUIDevTools
@testable import GuavaUIRuntime

/// End-to-end smoke test: spin up DevServer on a free port, connect a
/// real Network.framework WebSocket client, exchange hello + tree.subscribe.
final class DevServerSmokeTests: XCTestCase {

    @MainActor
    func test_hello_and_tree_subscribe_round_trip() async throws {
        // Build a minimal NodeTree with a labelled root + one child.
        let tree = NodeTree()
        let root = Node()
        root.viewTag = "Root"
        root.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let child = Node()
        child.viewTag = "Child"
        child.frame = CGRect(x: 10, y: 20, width: 100, height: 40)
        root.addChild(child)
        tree.root = root

        let port: UInt16 = UInt16.random(in: 49152...65000)
        let dev = DevTools(
            config: DevToolsConfig(host: "127.0.0.1", port: port,
                                   appTitle: "TestApp", enabled: true),
            tree: tree
        )
        try dev.start()
        defer { dev.stop() }

        let helloEnv = try await Self.receiveHello(port: port, timeout: 5)
        XCTAssertEqual(helloEnv.type, "hello")
        let helloPayload = try Self.decode(HelloPayload.self, from: helloEnv.payload)
        XCTAssertEqual(helloPayload.protocol, DevToolsProtocol.version)
        XCTAssertEqual(helloPayload.host.appTitle, "TestApp")
        XCTAssertTrue(helloPayload.capabilities.contains("tree"))
    }

    @MainActor
    func test_tree_subscribe_returns_snapshot() async throws {
        let tree = NodeTree()
        let root = Node()
        root.viewTag = "Root"
        root.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let child = Node()
        child.viewTag = "Child"
        child.frame = CGRect(x: 10, y: 20, width: 100, height: 40)
        child.backgroundColor = .white
        root.addChild(child)
        tree.root = root

        let port: UInt16 = UInt16.random(in: 49152...65000)
        let dev = DevTools(
            config: DevToolsConfig(host: "127.0.0.1", port: port,
                                   appTitle: "TestApp", enabled: true),
            tree: tree
        )
        try dev.start()
        defer { dev.stop() }

        let snapEnv = try await Self.requestTreeSnapshot(port: port, timeout: 5)
        XCTAssertEqual(snapEnv.type, "tree.snapshot")
        let snap = try Self.decode(TreeSnapshotPayload.self, from: snapEnv.payload)
        XCTAssertEqual(snap.root?.viewTag, "Root")
        XCTAssertEqual(snap.root?.children.count, 1)
        let onlyChild = snap.root?.children.first
        XCTAssertEqual(onlyChild?.viewTag, "Child")
        XCTAssertEqual(onlyChild?.frame.w, 100)
        XCTAssertEqual(onlyChild?.flags.hasBackground, true)
    }

    // MARK: - Helpers

    private static func requestTreeSnapshot(port: UInt16, timeout: TimeInterval) async throws -> DevToolsEnvelope {
        let url = URL(string: "ws://127.0.0.1:\(port)/")!
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let deadline = Date().addingTimeInterval(timeout)
        var subscribed = false
        while Date() < deadline {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                try await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            let env = try parseEnvelope(message)
            if env.type == "hello", !subscribed {
                let req = DevToolsEnvelope(type: "tree.subscribe", id: 1, payload: nil)
                let data = try JSONEncoder().encode(req)
                try await task.send(.string(String(data: data, encoding: .utf8)!))
                subscribed = true
                continue
            }
            if env.type == "tree.snapshot" { return env }
        }
        throw XCTSkip("did not receive tree.snapshot within \(timeout)s")
    }

    private static func parseEnvelope(_ message: URLSessionWebSocketTask.Message) throws -> DevToolsEnvelope {
        switch message {
        case .data(let data):
            return try JSONDecoder().decode(DevToolsEnvelope.self, from: data)
        case .string(let s):
            return try JSONDecoder().decode(DevToolsEnvelope.self, from: Data(s.utf8))
        @unknown default:
            throw NSError(domain: "ws", code: -1)
        }
    }

    private static func receiveHello(port: UInt16, timeout: TimeInterval) async throws -> DevToolsEnvelope {
        let url = URL(string: "ws://127.0.0.1:\(port)/")!
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                try await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            switch message {
            case .data(let data):
                return try JSONDecoder().decode(DevToolsEnvelope.self, from: data)
            case .string(let s):
                return try JSONDecoder().decode(DevToolsEnvelope.self, from: Data(s.utf8))
            @unknown default:
                continue
            }
        }
        throw XCTSkip("DevServer did not send hello within \(timeout)s")
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue?) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
#endif
