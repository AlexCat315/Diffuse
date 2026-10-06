import Foundation
import Testing
import NIOCore
import NIOEmbedded
import NIOWebSocket
import GuavaUIDevToolsProtocol
@testable import GuavaUIDevToolsServer

private final class TestConnection: DevToolsConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [Data] = []
    func send(text: Data) { lock.withLock { messages.append(text) } }
    func close() {}
    func take() -> [DevToolsEnvelope] {
        lock.withLock {
            defer { messages.removeAll() }
            return messages.compactMap { try? JSONDecoder().decode(DevToolsEnvelope.self, from: $0) }
        }
    }
}

private final class TestTransport: DevToolsTransport, @unchecked Sendable {
    var boundPort: UInt16? { 9229 }
    var onEvent: (@Sendable (DevToolsTransportEvent) -> Void)?
    func start(host: String, port: UInt16,
               onEvent: @escaping @Sendable (DevToolsTransportEvent) -> Void) throws { self.onEvent = onEvent }
    func stop() { onEvent = nil }
    func request(_ type: String, payload: JSONValue? = nil, connection: TestConnection) throws {
        let data = try JSONEncoder().encode(DevToolsEnvelope(type: type, id: 1, payload: payload))
        onEvent?(.text(connection, data))
    }
}

private enum Timeout: Error { case waitingForMessage }

@MainActor
private func receive(_ type: String, from connection: TestConnection) async throws -> DevToolsEnvelope {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if let message = connection.take().first(where: { $0.type == type }) { return message }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw Timeout.waitingForMessage
}

@Test @MainActor
func subscriptionsStateAndDisconnectUseSharedProtocol() async throws {
    let transport = TestTransport()
    let server = DevServer(config: DevToolsConfig(), transport: transport)
    var snapshots = 0
    var restored: [String: String]?
    var selections = [String]()
    var mirrorStops = 0
    server.snapshotProvider = { snapshots += 1; return TreeSnapshotPayload(root: nil) }
    server.stateCheckpointHandler = { ["count": "7"] }
    server.stateRestoreHandler = { restored = $0 }
    server.selectionHandler = { selections.append($0) }
    server.selectionClearHandler = { selections.append("clear") }
    server.mirrorStopHandler = { mirrorStops += 1 }
    try server.start()
    defer { server.stop() }
    server.broadcastTreeDelta()
    #expect(snapshots == 0)
    let connection = TestConnection()
    transport.onEvent?(.connected(connection))
    _ = try await receive("hello", from: connection)
    try transport.request("tree.subscribe", connection: connection)
    _ = try await receive("tree.snapshot", from: connection)
    #expect(snapshots == 1)
    try transport.request("state.checkpoint", connection: connection)
    let checkpoint = try await receive("state.checkpoint.ok", from: connection)
    #expect(checkpoint.payload?.objectValue?["count"]?.stringValue == "7")
    try transport.request("state.restore", payload: .object(["count": .number(2)]), connection: connection)
    _ = try await receive("state.restore.err", from: connection)
    #expect(restored == nil)
    try transport.request("state.restore", payload: .object(["count": .string("9")]), connection: connection)
    _ = try await receive("state.restore.ok", from: connection)
    #expect(restored == ["count": "9"])
    try transport.request("mirror.input", connection: connection)
    _ = try await receive("mirror.input.err", from: connection)
    try transport.request("mirror.start", connection: connection)
    _ = try await receive("mirror.start.ok", from: connection)
    try transport.request("select.node", payload: .object(["id": .string("42")]), connection: connection)
    _ = try await receive("select.node.ok", from: connection)
    transport.onEvent?(.disconnected(connection))
    let deadline = ContinuousClock.now + .seconds(3)
    while !selections.contains("clear"), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(selections == ["42", "clear"])
    #expect(mirrorStops == 1)
}

@Test
func loopbackBindingRestartAndOccupiedPort() throws {
    let first = NIODevToolsTransport()
    try first.start(host: "localhost", port: 0) { _ in }
    defer { first.stop() }
    let port = try #require(first.boundPort)
    #expect(port > 0)
    let second = NIODevToolsTransport()
    #expect(throws: (any Error).self) { try second.start(host: "127.0.0.1", port: port) { _ in } }
    try second.start(host: "127.0.0.1", port: 0) { _ in }
    second.stop()
    #expect(second.boundPort == nil)
    #expect(throws: DevServerConfigurationError.self) {
        try second.start(host: "example.com", port: 0) { _ in }
    }
}

private final class TransportEvents: @unchecked Sendable {
    var messages = [Data]()
    func record(_ event: DevToolsTransportEvent) {
        if case .text(_, let data) = event { messages.append(data) }
    }
}

@Test
func fragmentedTextSurvivesInterleavedPing() throws {
    let events = TransportEvents()
    let channel = EmbeddedChannel(handler: DevToolsWebSocketHandler(onEvent: events.record))
    defer { _ = try? channel.finish() }
    func frame(_ opcode: WebSocketOpcode, _ text: String, fin: Bool) -> WebSocketFrame {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        let mask: WebSocketMaskingKey = [1, 2, 3, 4]
        buffer.webSocketMask(mask)
        return WebSocketFrame(fin: fin, opcode: opcode, maskKey: mask, data: buffer)
    }
    try channel.writeInbound(frame(.text, "hel", fin: false))
    try channel.writeInbound(frame(.ping, "ping", fin: true))
    let pong = try #require(try channel.readOutbound(as: WebSocketFrame.self))
    #expect(pong.opcode == .pong)
    #expect(String(decoding: pong.data.readableBytesView, as: UTF8.self) == "ping")
    try channel.writeInbound(frame(.continuation, "lo", fin: true))
    #expect(events.messages == [Data("hello".utf8)])
}

@Test
func unmaskedClientFramesAreRejected() throws {
    let channel = EmbeddedChannel(handler: DevToolsWebSocketHandler(onEvent: { _ in }))
    defer { _ = try? channel.finish() }
    var data = channel.allocator.buffer(capacity: 2)
    data.writeString("{}")
    try channel.writeInbound(WebSocketFrame(fin: true, opcode: .text, data: data))
    var close = try #require(try channel.readOutbound(as: WebSocketFrame.self))
    #expect(close.opcode == .connectionClose)
    #expect(close.data.readInteger(as: UInt16.self) == 1002)
}

@Test @MainActor
func stateDiffRestoreResultAndRecordingOwnership() async throws {
    let transport = TestTransport()
    let server = DevServer(config: DevToolsConfig(), transport: transport)
    var value = "2"
    var stops = 0
    var replays = 0
    server.stateCheckpointHandler = { ["count": value] }
    server.stateRestoreResultHandler = { state in
        guard let next = state["count"], let integer = Int(next), integer >= 0 else { return false }
        value = next; return true
    }
    server.recordingStartHandler = { true }
    server.recordingStopHandler = { stops += 1; return InputRecording(initialState: ["count":"2"]) }
    server.recordingReplayHandler = { recording in replays += 1; value = recording.initialState["count"]!; return true }
    try server.start(); defer { server.stop() }
    let owner = TestConnection()
    let other = TestConnection()
    transport.onEvent?(.connected(owner)); _ = try await receive("hello", from: owner)
    transport.onEvent?(.connected(other)); _ = try await receive("hello", from: other)
    try transport.request("state.diff", payload: .object(["count":.string("1")]), connection: owner)
    let difference = try await receive("state.diff.ok", from: owner)
    #expect(DevToolsCodec.decode(StateDifference.self, difference.payload)?.changed["count"]?.after == "2")
    try transport.request("state.restore", payload: .object(["count":.string("-1")]), connection: owner)
    _ = try await receive("state.restore.err", from: owner)
    #expect(value == "2")
    try transport.request("input.record.start", connection: owner)
    _ = try await receive("input.record.start.ok", from: owner)
    try transport.request("input.record.stop", connection: other)
    _ = try await receive("input.record.stop.err", from: other)
    #expect(stops == 0)
    try transport.request("select.clear", connection: owner)
    _ = try await receive("select.clear.ok", from: owner)
    #expect(stops == 0)
    try transport.request("input.record.stop", connection: owner)
    let recording = try await receive("input.record.stop.ok", from: owner)
    #expect(stops == 1)
    try transport.request("input.replay", payload: recording.payload, connection: owner)
    _ = try await receive("input.replay.ok", from: owner)
    #expect(replays == 1)
    try transport.request("input.record.start", connection: owner)
    _ = try await receive("input.record.start.ok", from: owner)
    transport.onEvent?(.disconnected(owner))
    let deadline = ContinuousClock.now + .seconds(3)
    while stops < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(stops == 2)
}
