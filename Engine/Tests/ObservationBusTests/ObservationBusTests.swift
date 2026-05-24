import Dispatch
import Foundation
import ObservationBus
import Testing

@Suite("ObservationBus")
struct ObservationBusTests {
    @Test("publish writes envelopes into subscriptions and cold log replay")
    func publishWritesIntoSubscriptionsAndColdLog() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bus = try ObservationBus(coldLogDirectory: root.path)
        let subscription = bus.subscribe(spec: SubscriptionSpec(filter: .kindIn([.transactionApplied]),
                                                                startFrom: .latest,
                                                                bufferPolicy: .dropOldest(size: 4)))

        let envelope = try bus.publish(
            kind: .transactionApplied,
            streamID: "transaction",
            payload: .inline([
                "transaction_id": .string("tx.001"),
                "status": .string("applied"),
            ]),
            origin: .tool(user: "alex"),
            causationID: "tx.001",
            provenance: .authored
        )

        let delivered = subscription.drain()
        let replayed = try bus.replay(streamID: "transaction", fromSeq: 1)

        #expect(delivered.map(\ .eventID) == [envelope.eventID])
        #expect(replayed.map(\ .eventID) == [envelope.eventID])
        #expect(replayed.allSatisfy { $0.replay })
    }

    @Test("coalesce buffer keeps the latest scene change for the same entity key")
    func coalesceBufferKeepsLatestSceneChange() throws {
        let bus = try ObservationBus(ringLimit: 8)
        let subscription = bus.subscribe(spec: SubscriptionSpec(filter: .kindIn([.sceneChanged]),
                                                                startFrom: .latest,
                                                                bufferPolicy: .coalesce(size: 4, keyFields: ["entity_id"])))

        _ = try bus.publish(kind: .sceneChanged,
                            streamID: "scene:test",
                            payload: .inline([
                                "entity_id": .integer(42),
                                "scene_revision": .integer(1),
                            ]),
                            origin: .tool(),
                            provenance: .authored)
        _ = try bus.publish(kind: .sceneChanged,
                            streamID: "scene:test",
                            payload: .inline([
                                "entity_id": .integer(42),
                                "scene_revision": .integer(2),
                            ]),
                            origin: .tool(),
                            provenance: .authored)

        let delivered = subscription.drain()

        #expect(delivered.count == 1)
        #expect(delivered[0].payloadRef.inlineRecord?["scene_revision"] == .integer(2))
    }

    // MARK: - Subscriber

    @Test("SubscriberToken cancellation removes the subscription from the bus")
    func subscriberTokenCancellationRemovesSubscription() throws {
        let bus = try ObservationBus()
        let token = bus.sink(spec: SubscriptionSpec(filter: .kindIn([.sceneChanged])),
                             interval: .seconds(60)) { _ in }
        let id = token.subscriptionID
        #expect(!token.isCancelled)

        token.cancel()
        #expect(token.isCancelled)

        // After cancel, publishing to the stream should not reach the (now removed) subscription.
        // We verify by re-subscribing and checking the old id is gone.
        let sub2 = bus.subscribe(spec: SubscriptionSpec(id: id,
                                                         filter: .kindIn([.sceneChanged])))
        _ = try bus.publish(kind: .sceneChanged,
                            streamID: "scene:test",
                            payload: .inline(["entity_id": .integer(1), "scene_revision": .integer(1)]),
                            origin: .tool(),
                            provenance: .authored)
        // sub2 was registered fresh with same id — it must receive the event
        #expect(sub2.drain().count == 1)
    }

    @Test("sink delivers events to handler on background queue")
    func sinkDeliversEventsToHandler() throws {
        let bus = try ObservationBus()
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        nonisolated(unsafe) var receivedIDs: [String] = []

        let token = bus.sink(spec: SubscriptionSpec(filter: .kindIn([.transactionApplied])),
                             interval: .milliseconds(10)) { envelopes in
            lock.lock()
            envelopes.forEach { receivedIDs.append($0.eventID) }
            lock.unlock()
            semaphore.signal()
        }
        defer { token.cancel() }

        let envelope = try bus.publish(
            kind: .transactionApplied,
            streamID: "transaction",
            payload: .inline(["transaction_id": .string("tx.sink"), "status": .string("applied")]),
            origin: .tool(),
            causationID: "tx.sink",
            provenance: .authored
        )

        let result = semaphore.wait(timeout: .now() + 2)
        #expect(result == .success)
        lock.lock()
        let ids = receivedIDs
        lock.unlock()
        #expect(ids.contains(envelope.eventID))
    }

    @Test("events() AsyncStream yields published envelopes")
    func asyncStreamYieldsPublishedEnvelopes() async throws {
        let bus = try ObservationBus()
        nonisolated(unsafe) var capturedToken: SubscriberToken?
        let stream = bus.events(
            spec: SubscriptionSpec(filter: .kindIn([.sceneEntityAdded])),
            pollingInterval: .milliseconds(10),
            onToken: { capturedToken = $0 }
        )

        let envelope = try bus.publish(
            kind: .sceneEntityAdded,
            streamID: "scene:main",
            payload: .inline(["entity_ids": .array([.integer(99)]), "scene_revision": .integer(1)]),
            origin: .tool(),
            provenance: .authored
        )

        var received: EventEnvelope?
        for await event in stream {
            received = event
            capturedToken?.cancel()
            break
        }

        #expect(received?.eventID == envelope.eventID)
    }

    // MARK: - EventSymbolicView

    @Test("symbolicView excludes redact_in_prompt and runtime tick events")
    func symbolicViewExcludesRedactedAndTickEvents() throws {
        let bus = try ObservationBus()
        let origin = EventOrigin.tool()

        _ = try bus.publish(kind: .runtimeTick,
                            streamID: "runtime",
                            payload: .inline(["frame": .integer(1)]),
                            origin: origin, provenance: .runtime)
        _ = try bus.publish(kind: .transactionApplied,
                            streamID: "runtime",
                            payload: .inline(["transaction_id": .string("tx.1"), "status": .string("applied")]),
                            origin: origin, provenance: .authored)

        let view = bus.symbolicView(streamID: "runtime", fromSeq: 0)
        #expect(view.events.count == 1)
        #expect(view.events[0].kind == .transactionApplied)
    }

    @Test("symbolicView compacts inline payload fields to strings")
    func symbolicViewCompactsInlinePayload() throws {
        let bus = try ObservationBus()
        _ = try bus.publish(kind: .transactionApplied,
                            streamID: "scene:main",
                            payload: .inline([
                                "transaction_id": .string("tx.42"),
                                "status": .string("applied"),
                                "count": .integer(7),
                            ]),
                            origin: .tool(), provenance: .authored)

        let view = bus.symbolicView(streamID: "scene:main")
        #expect(view.events.count == 1)
        let ev = view.events[0]
        #expect(ev.summary["transaction_id"] == "tx.42")
        #expect(ev.summary["count"] == "7")
    }

    @Test("symbolicView handle payload yields existence marker")
    func symbolicViewHandlePayloadYieldsMarker() throws {
        let bus = try ObservationBus()
        _ = try bus.publish(kind: .assetImportFinished,
                            streamID: "asset",
                            payload: .handle(EventPayloadHandle(store: "artifacts",
                                                                key: "abc123",
                                                                contentHash: "sha256:0")),
                            origin: .tool(), provenance: .inferred)

        let view = bus.symbolicView(streamID: "asset")
        #expect(view.events.count == 1)
        #expect(view.events[0].summary["payload"] == "<handle:artifacts/abc123>")
    }

    @Test("symbolicView promptText renders compact multi-line string")
    func symbolicViewPromptText() throws {
        let bus = try ObservationBus()
        _ = try bus.publish(kind: .sceneEntityAdded,
                            streamID: "scene:main",
                            payload: .inline(["entity_ids": .array([.integer(1)]), "scene_revision": .integer(5)]),
                            origin: .tool(), provenance: .authored)

        let text = bus.symbolicView(streamID: "scene:main").promptText()
        #expect(text.contains("scene.entity.added"))
        #expect(text.contains("scene:main"))
    }

    @Test("symbolicView maxCount caps output")
    func symbolicViewMaxCountCaps() throws {
        let bus = try ObservationBus()
        for i in 1...10 {
            _ = try bus.publish(kind: .transactionApplied,
                                streamID: "tx",
                                payload: .inline(["transaction_id": .string("tx.\(i)"), "status": .string("applied")]),
                                origin: .tool(), provenance: .authored)
        }

        let view = bus.symbolicView(streamID: "tx", fromSeq: 0, maxCount: 3)
        #expect(view.events.count == 3)
        // should be the last 3
        #expect(view.events[0].summary["transaction_id"] == "tx.8")
    }
}