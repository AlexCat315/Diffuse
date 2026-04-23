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
}