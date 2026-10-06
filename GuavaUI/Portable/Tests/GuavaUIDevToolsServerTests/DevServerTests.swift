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
    func takeNextData() -> Data? {
        lock.withLock { messages.isEmpty ? nil : messages.removeFirst() }
    }
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

@MainActor private final class ObservationTestValue { var number = "1" }
@MainActor private final class TreeTestRevision {
    var captures = 0
    var name = "initial"
}

private final class HostInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@MainActor () -> Void] = []
    func add(_ operation: @escaping @MainActor () -> Void) { lock.withLock { operations.append(operation) } }
    var count: Int { lock.withLock { operations.count } }
    @MainActor func drain(reversed: Bool = false) {
        let pending = lock.withLock { let values = operations; operations.removeAll(); return values }
        for operation in reversed ? pending.reversed() : pending { operation() }
    }
}

@MainActor
private func receive(_ type: String, from connection: TestConnection) async throws -> DevToolsEnvelope {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if let message = connection.take().first(where: { $0.type == type }) { return message }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw Timeout.waitingForMessage
}

private struct TreeWireMessage: Decodable {
    let type: String
    let id: Int?
    let payload: TreeSnapshotPayload
}

@MainActor
private func receiveTree(_ type: String, from connection: TestConnection) async throws -> TreeWireMessage {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if let data = connection.takeNextData() {
            if let message = try? JSONDecoder().decode(TreeWireMessage.self, from: data), message.type == type { return message }
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw Timeout.waitingForMessage
}

@Test @MainActor
func largeTreeBroadcastCoalescesBurstsAndDeliversFinalIdleChange() async throws {
    let transport = TestTransport(), connection = TestConnection()
    let server = DevServer(config: DevToolsConfig(), transport: transport)
    let flags = NodeFlags(hitTestable: true, focusable: false, clipsToBounds: false, hasBackground: true, hasBorder: false)
    let children = (0..<1_036).map { index in
        NodeSummary(id: String(index), viewTag: "EditorPanel", frame: NodeFrame(x: 1, y: 2, w: 3, h: 4),
                    flags: flags, children: [], elementID: String(index),
                    source: SourceLocationPayload(fileID: "Editor/Panel.swift", filePath: "/project/Panel.swift", line: index + 1, column: 2))
    }
    let revision = TreeTestRevision()
    server.snapshotProvider = {
        revision.captures += 1
        return TreeSnapshotPayload(root: NodeSummary(id: "root", debugName: revision.name,
            frame: NodeFrame(x: 0, y: 0, w: 1280, h: 720), flags: flags, children: children))
    }
    try server.start(); defer { server.stop() }
    transport.onEvent?(.connected(connection)); _ = try await receive("hello", from: connection)
    try transport.request("tree.subscribe", connection: connection)
    let initial = try await receiveTree("tree.snapshot", from: connection)
    #expect(initial.id == 1 && initial.payload.root?.children.count == 1_036)
    #expect(initial.payload.root?.children.last?.source?.line == 1_036)
    revision.name = "first"
    server.broadcastTreeDelta()
    for index in 0..<100 { revision.name = "change.\(index)"; server.broadcastTreeDelta() }
    // The burst does not capture or queue 100 full snapshots on the UI thread.
    #expect(revision.captures == 2)
    let first = try await receiveTree("tree.delta", from: connection)
    #expect(first.id == nil && first.payload.root?.debugName == "first")
    // No further render or broadcast is needed to deliver the last change.
    let final = try await receiveTree("tree.delta", from: connection)
    #expect(final.payload.root?.debugName == "change.99" && revision.captures == 3)
    try transport.request("tree.unsubscribe", connection: connection)
    _ = try await receive("tree.unsubscribe.ok", from: connection)
    server.broadcastTreeDelta()
    #expect(revision.captures == 3)
}

@Test @MainActor
func deeplyNestedEditorTreeEncodesOffTheSceneThread() async throws {
    let transport = TestTransport(), connection = TestConnection()
    let server = DevServer(config: DevToolsConfig(), transport: transport)
    let flags = NodeFlags(hitTestable: false, focusable: false, clipsToBounds: false, hasBackground: false, hasBorder: false)
    var root = NodeSummary(id: "leaf", frame: NodeFrame(x: 0, y: 0, w: 1, h: 1), flags: flags, children: [])
    for index in 0..<128 {
        root = NodeSummary(id: "wrapper.\(index)", frame: NodeFrame(x: 0, y: 0, w: 1, h: 1), flags: flags, children: [root])
    }
    let snapshot = TreeSnapshotPayload(root: root)
    server.snapshotProvider = { snapshot }
    try server.start(); defer { server.stop() }
    transport.onEvent?(.connected(connection)); _ = try await receive("hello", from: connection)
    try transport.request("tree.subscribe", connection: connection)
    let initial = try await receiveTree("tree.snapshot", from: connection)
    var node = try #require(initial.payload.root)
    for _ in 0..<128 { node = try #require(node.children.first) }
    #expect(node.id == "leaf")
    server.broadcastTreeDelta()
    let update = try await receiveTree("tree.delta", from: connection)
    #expect(update.payload.root?.id == root.id)
}

@Test @MainActor
func staleTreeSubscribeCannotCaptureAfterServerRestart() async throws {
    let transport = TestTransport(), inbox = HostInbox(), old = TestConnection(), current = TestConnection()
    let server = DevServer(config: DevToolsConfig(), transport: transport)
    var captures = 0
    server.hostMainExecutor = { inbox.add($0) }
    server.snapshotProvider = { captures += 1; return TreeSnapshotPayload(root: nil) }
    try server.start(); defer { server.stop() }
    transport.onEvent?(.connected(old)); _ = try await receive("hello", from: old)
    try transport.request("tree.subscribe", connection: old)
    let deadline = ContinuousClock.now + .seconds(3)
    while inbox.count == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(inbox.count == 1)
    server.stop(); try server.start()
    transport.onEvent?(.connected(current)); _ = try await receive("hello", from: current)
    inbox.drain()
    #expect(captures == 0 && old.take().isEmpty)
    try transport.request("tree.subscribe", connection: current)
    let nextDeadline = ContinuousClock.now + .seconds(3)
    while inbox.count == 0, ContinuousClock.now < nextDeadline { try await Task.sleep(for: .milliseconds(5)) }
    inbox.drain()
    _ = try await receiveTree("tree.snapshot", from: current)
    #expect(captures == 1)
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

@Test @MainActor
func temporaryInspectionIsExclusiveAndDisconnectCleansOnlyItsLease() async throws {
    let transport = TestTransport(), inbox = HostInbox()
    let server = DevServer(config: DevToolsConfig(), transport: transport)
    var applied = 0, resets = 0
    server.hostMainExecutor = { inbox.add($0) }
    server.inspectionHandler = { request in applied += 1; return DevToolsEnvelope(type: request.type + ".ok", id: request.id) }
    server.inspectionResetHandler = { resets += 1 }
    try server.start(); defer { server.stop(); inbox.drain() }
    let owner = TestConnection(), other = TestConnection()
    transport.onEvent?(.connected(owner)); _ = try await receive("hello", from: owner)
    transport.onEvent?(.connected(other)); _ = try await receive("hello", from: other)
    try transport.request("inspect.pick.start", connection: owner)
    try transport.request("inspect.pick.start", connection: other)
    let busy = try await receive("inspect.pick.start.err", from: other)
    #expect(busy.payload?.objectValue?["code"]?.stringValue == "busy")
    inbox.drain(); _ = try await receive("inspect.pick.start.ok", from: owner)
    #expect(applied == 1 && resets == 0)
    // Queue a style command then disconnect before the main thread runs it.
    try transport.request("inspect.style.undo", connection: owner)
    transport.onEvent?(.disconnected(owner))
    try transport.request("inspect.pick.start", connection: other)
    let deadline = ContinuousClock.now + .seconds(3)
    while inbox.count < 4, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(inbox.count == 4)
    // Simulate MainActor task reordering: a new lease runs before old cleanup.
    inbox.drain(reversed: true)
    _ = try await receive("inspect.pick.start.ok", from: other)
    #expect(applied == 2 && resets == 1)
    server.stop(); inbox.drain()
    #expect(resets == 2)
}

@Test @MainActor
func observationStreamsAreIndependentAndTimelineStopsAfterLastDisconnect() async throws {
    let transport = TestTransport(), one = TestConnection(), two = TestConnection()
    let server = DevServer(config: DevToolsConfig(), transport: transport)
    var reads = [[String]](), capture = false
    let value = ObservationTestValue()
    server.stateObservationProvider = { ids in
        reads.append(ids)
        return StateObservationPayload(registered: [RegisteredStatePayload(id: "count", name: "count", valueType: "Int")],
            values: ids.contains("count") ? [ObservedStatePayload(id: "count", summary: value.number, truncated: false)] : [])
    }
    server.timelineCaptureHandler = { capture = $0 }
    server.timelineProvider = { _ in TimelineSnapshotPayload(events: [TimelineEventPayload(sequence: 1, phase: "draw", name: "Draw", scopeID: nil, startMs: 1, durationMs: 2)]) }
    try server.start(); defer { server.stop() }
    server.broadcastObservations(); #expect(reads.isEmpty && !capture)
    transport.onEvent?(.connected(one)); _ = try await receive("hello", from: one)
    transport.onEvent?(.connected(two)); _ = try await receive("hello", from: two)
    try transport.request("state.list", connection: one)
    let metadata = try await receive("state.list.ok", from: one)
    #expect(DevToolsCodec.decode(StateObservationPayload.self, metadata.payload)?.values.isEmpty == true && reads == [[]])
    try transport.request("state.subscribe", payload: DevToolsCodec.json(StateWatchPayload(ids: ["count"])), connection: one)
    _ = try await receive("state.subscribe.ok", from: one)
    value.number = "2"; server.broadcastObservations()
    let updated = try await receive("state.observation", from: one)
    #expect(DevToolsCodec.decode(StateObservationPayload.self, updated.payload)?.values.first?.summary == "2")
    #expect(two.take().isEmpty)
    try transport.request("state.unsubscribe", connection: one); _ = try await receive("state.unsubscribe.ok", from: one)
    let readCount = reads.count; server.broadcastObservations(); #expect(reads.count == readCount)
    try transport.request("timeline.subscribe", connection: one); _ = try await receive("timeline.events", from: one)
    try transport.request("timeline.subscribe", connection: two); _ = try await receive("timeline.events", from: two)
    #expect(capture)
    try transport.request("timeline.unsubscribe", connection: one); _ = try await receive("timeline.unsubscribe.ok", from: one)
    try await Task.sleep(for: .milliseconds(20)); #expect(capture)
    transport.onEvent?(.disconnected(two))
    let deadline = ContinuousClock.now + .seconds(3)
    while capture && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!capture)
}
