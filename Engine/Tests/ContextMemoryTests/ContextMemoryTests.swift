import ContextMemory
import IntentRuntime
import Testing
import Foundation

// MARK: - Helpers

private func upserts(from mutations: [ContextMemoryMutation]) -> [ContextEntry] {
    mutations.compactMap { if case let .upsert(e) = $0 { return e } else { return nil } }
}

private func deletedIDs(from mutations: [ContextMemoryMutation]) -> [String] {
    mutations.compactMap { if case let .delete(id) = $0 { return id } else { return nil } }
}

@Suite("ContextMemory")
struct ContextMemoryTests {

    // MARK: - editAppliedReducer

    @Test("editAppliedReducer produces entityEdit entry from editApplied event")
    func editAppliedReducerProducesEntry() {
        let mutations = editAppliedReducer([:], .editApplied(editID: "e1", summary: "moved cube", revision: 1))
        let entries = upserts(from: mutations)
        #expect(entries.count == 1)
        let entry = entries[0]
        #expect(entry.id == "edit:e1")
        #expect(entry.kind == .entityEdit)
        #expect(entry.subject == "session")
        #expect(entry.payload["summary"] == "moved cube")
        #expect(entry.payload["edit_id"] == "e1")
        #expect(entry.revision == 1)
    }

    @Test("editAppliedReducer returns empty for empty editID")
    func editAppliedReducerRejectsEmptyID() {
        let result = editAppliedReducer([:], .editApplied(editID: "", summary: "x", revision: 0))
        #expect(result.isEmpty)
    }

    @Test("editAppliedReducer returns empty for empty summary")
    func editAppliedReducerRejectsEmptySummary() {
        let result = editAppliedReducer([:], .editApplied(editID: "e2", summary: "", revision: 0))
        #expect(result.isEmpty)
    }

    @Test("editAppliedReducer is idempotent on replay (stable fields)")
    func editAppliedReducerIsIdempotent() {
        let event = WorldEvent.editApplied(editID: "e3", summary: "rename", revision: 5)
        let firstEntries = upserts(from: editAppliedReducer([:], event))
        var existing: [String: ContextEntry] = [:]
        for e in firstEntries { existing[e.id] = e }
        let secondEntries = upserts(from: editAppliedReducer(existing, event))
        #expect(firstEntries.count == secondEntries.count)
        for (a, b) in zip(firstEntries, secondEntries) {
            #expect(a.id == b.id)
            #expect(a.kind == b.kind)
            #expect(a.subject == b.subject)
            #expect(a.payload == b.payload)
            #expect(a.importance == b.importance)
            #expect(a.revision == b.revision)
        }
    }

    // MARK: - entityAddedReducer

    @Test("entityAddedReducer produces sceneAnnotation from entityAdded")
    func entityAddedReducerProducesEntry() {
        let entries = upserts(from: entityAddedReducer([:], .entityAdded(ref: "scene:7", name: "Cube", kind: "mesh")))
        #expect(entries.count == 1)
        let entry = entries[0]
        #expect(entry.id == "entity_added:scene:7")
        #expect(entry.kind == .sceneAnnotation)
        #expect(entry.subject == "scene:7")
        #expect(entry.payload["name"] == "Cube")
        #expect(entry.payload["ref"] == "scene:7")
        #expect(entry.payload["kind"] == "mesh")
    }

    @Test("entityAddedReducer omits kind when nil")
    func entityAddedReducerOmitsNilKind() {
        let entries = upserts(from: entityAddedReducer([:], .entityAdded(ref: "scene:8", name: "Empty", kind: nil)))
        #expect(entries[0].payload["kind"] == nil)
    }

    @Test("entityAddedReducer returns empty for non-entityAdded events")
    func entityAddedReducerIgnoresOtherEvents() {
        let result = entityAddedReducer([:], .editApplied(editID: "x", summary: "y", revision: 0))
        #expect(result.isEmpty)
    }

    // MARK: - entityRemovedReducer

    @Test("entityRemovedReducer deletes entity_added entry")
    func entityRemovedReducerDeletesAddedEntry() {
        let existing: [String: ContextEntry] = [
            "entity_added:scene:5": ContextEntry(
                id: "entity_added:scene:5", kind: .sceneAnnotation,
                subject: "scene:5", payload: [:]),
        ]
        let mutations = entityRemovedReducer(existing, .entityRemoved(ref: "scene:5"))
        let ids = deletedIDs(from: mutations)
        #expect(ids.contains("entity_added:scene:5"))
    }

    @Test("entityRemovedReducer deletes all inferred entries for removed entity")
    func entityRemovedReducerDeletesInferredEntries() {
        let existing: [String: ContextEntry] = [
            "entity_added:scene:6": ContextEntry(
                id: "entity_added:scene:6", kind: .sceneAnnotation,
                subject: "scene:6", payload: [:]),
            "inferred:scene:6:material": ContextEntry(
                id: "inferred:scene:6:material", kind: .sceneAnnotation,
                subject: "scene:6", payload: [:]),
            "inferred:scene:6:roughness": ContextEntry(
                id: "inferred:scene:6:roughness", kind: .sceneAnnotation,
                subject: "scene:6", payload: [:]),
            "entity_added:scene:7": ContextEntry(
                id: "entity_added:scene:7", kind: .sceneAnnotation,
                subject: "scene:7", payload: [:]),
        ]
        let mutations = entityRemovedReducer(existing, .entityRemoved(ref: "scene:6"))
        let ids = Set(deletedIDs(from: mutations))
        #expect(ids.contains("entity_added:scene:6"))
        #expect(ids.contains("inferred:scene:6:material"))
        #expect(ids.contains("inferred:scene:6:roughness"))
        #expect(!ids.contains("entity_added:scene:7"))
    }

    @Test("entityRemovedReducer returns empty when entity has no memory entries")
    func entityRemovedReducerReturnsEmptyForUnknownEntity() {
        let result = entityRemovedReducer([:], .entityRemoved(ref: "scene:99"))
        #expect(result.isEmpty)
    }

    @Test("entityRemovedReducer ignores non-entityRemoved events")
    func entityRemovedReducerIgnoresOtherEvents() {
        let result = entityRemovedReducer([:], .entityAdded(ref: "scene:1", name: "X", kind: nil))
        #expect(result.isEmpty)
    }

    // MARK: - highConfidenceInferredReducer

    @Test("highConfidenceInferredReducer fires at exactly 0.8 confidence")
    func highConfidenceReducerAtThreshold() {
        let event = WorldEvent.entityInferredUpdated(
            ref: "scene:10", property: "material", value: .string("wood"),
            confidence: 0.8, source: nil)
        let entries = upserts(from: highConfidenceInferredReducer([:], event))
        #expect(entries.count == 1)
        #expect(entries[0].id == "inferred:scene:10:material")
        #expect(entries[0].payload["value"] == "wood")
    }

    @Test("highConfidenceInferredReducer rejects confidence below 0.8")
    func highConfidenceReducerBelowThreshold() {
        let event = WorldEvent.entityInferredUpdated(
            ref: "scene:10", property: "material", value: .string("wood"),
            confidence: 0.79, source: nil)
        let result = highConfidenceInferredReducer([:], event)
        #expect(result.isEmpty)
    }

    @Test("highConfidenceInferredReducer preserves previous revision")
    func highConfidenceReducerPreservesRevision() {
        let entryID = "inferred:scene:11:roughness"
        let prev = ContextEntry(
            id: entryID, kind: .sceneAnnotation, subject: "scene:11",
            payload: ["value": "0.3"], importance: 0.9, revision: 42)
        let existing = [entryID: prev]
        let event = WorldEvent.entityInferredUpdated(
            ref: "scene:11", property: "roughness", value: .float(0.5),
            confidence: 0.95, source: "VisionAdapter")
        let entries = upserts(from: highConfidenceInferredReducer(existing, event))
        #expect(entries[0].revision == 42)
        #expect(entries[0].payload["source"] == "VisionAdapter")
    }

    @Test("highConfidenceInferredReducer encodes all value variants")
    func highConfidenceReducerValueVariants() {
        func makeEvent(_ val: WorldPropertyValue) -> WorldEvent {
            .entityInferredUpdated(ref: "scene:1", property: "p", value: val, confidence: 1.0, source: nil)
        }
        let floatEntries = upserts(from: highConfidenceInferredReducer([:], makeEvent(.float(3.14))))
        let boolEntries  = upserts(from: highConfidenceInferredReducer([:], makeEvent(.bool(true))))
        let vec3Entries  = upserts(from: highConfidenceInferredReducer([:], makeEvent(.vec3(1, 2, 3))))
        let vec4Entries  = upserts(from: highConfidenceInferredReducer([:], makeEvent(.vec4(1, 2, 3, 4))))
        #expect(floatEntries[0].payload["value"] == "3.14")
        #expect(boolEntries[0].payload["value"] == "true")
        #expect(vec3Entries[0].payload["value"] == "(1.0, 2.0, 3.0)")
        #expect(vec4Entries[0].payload["value"] == "(1.0, 2.0, 3.0, 4.0)")
    }

    // MARK: - ReducerRegistry

    @Test("ReducerRegistry.default applies all four built-in reducers")
    func defaultRegistryAppliesAllReducers() {
        let registry = ReducerRegistry.default
        let editMutations   = registry.apply(existing: [:], event: .editApplied(editID: "e99", summary: "test", revision: 0))
        let addMutations    = registry.apply(existing: [:], event: .entityAdded(ref: "scene:99", name: "S", kind: nil))
        let inferMutations  = registry.apply(existing: [:], event: .entityInferredUpdated(
            ref: "scene:99", property: "color", value: .string("red"), confidence: 0.9, source: nil))
        #expect(!upserts(from: editMutations).isEmpty)
        #expect(!upserts(from: addMutations).isEmpty)
        #expect(!upserts(from: inferMutations).isEmpty)
    }

    @Test("ReducerRegistry.adding accumulates mutations from both reducers")
    func registryAddingAccumulatesResults() {
        let r1: ContextMemoryReducer = { _, _ in
            [.upsert(ContextEntry(id: "r1", kind: .entityEdit, subject: "s", payload: [:]))]
        }
        let r2: ContextMemoryReducer = { _, _ in
            [.upsert(ContextEntry(id: "r2", kind: .sceneAnnotation, subject: "s", payload: [:]))]
        }
        let registry = ReducerRegistry(reducers: [r1]).adding(r2)
        let mutations = registry.apply(existing: [:], event: .editApplied(editID: "x", summary: "y", revision: 0))
        let ids = upserts(from: mutations).map(\.id)
        #expect(ids.contains("r1"))
        #expect(ids.contains("r2"))
    }

    // MARK: - ContextMemoryStore

    @Test("store.apply upserts entries from events")
    func storeApplyUpserts() async throws {
        let store = try ContextMemoryStore()
        await store.apply(event: .entityAdded(ref: "scene:1", name: "A", kind: nil))
        let entries = await store.allEntries()
        #expect(entries.count == 1)
        #expect(entries[0].subject == "scene:1")
    }

    @Test("store.apply deletes entries on entityRemoved")
    func storeApplyDeletesOnRemoval() async throws {
        let store = try ContextMemoryStore()
        await store.apply(event: .entityAdded(ref: "scene:1", name: "A", kind: nil))
        await store.apply(event: .entityRemoved(ref: "scene:1"))
        let entries = await store.allEntries()
        #expect(entries.isEmpty)
    }

    @Test("store.apply batch is equivalent to sequential apply")
    func storeApplyBatchEquivalent() async throws {
        let store1 = try ContextMemoryStore()
        let store2 = try ContextMemoryStore()
        let events: [WorldEvent] = [
            .entityAdded(ref: "scene:2", name: "B", kind: "mesh"),
            .editApplied(editID: "e1", summary: "moved", revision: 1),
        ]
        for ev in events { await store1.apply(event: ev) }
        await store2.apply(events: events)
        let a1 = await store1.allEntries().sorted { $0.id < $1.id }
        let a2 = await store2.allEntries().sorted { $0.id < $1.id }
        #expect(a1.map(\.id) == a2.map(\.id))
    }

    @Test("store replay is idempotent")
    func storeReplayIsIdempotent() async throws {
        let store = try ContextMemoryStore()
        let events: [WorldEvent] = [
            .entityAdded(ref: "scene:3", name: "C", kind: nil),
            .editApplied(editID: "e2", summary: "rotated", revision: 2),
        ]
        await store.apply(events: events)
        let before = await store.allEntries().sorted { $0.id < $1.id }
        await store.apply(events: events)
        let after = await store.allEntries().sorted { $0.id < $1.id }
        #expect(before.map(\.id) == after.map(\.id))
        #expect(before.count == after.count)
    }

    @Test("store evicts lowest-importance entries when at capacity")
    func storeEvictsAtCapacity() async throws {
        let store = try ContextMemoryStore(capacity: 2)
        // entityAddedReducer importance = 0.3, editAppliedReducer importance = 0.4
        await store.apply(event: .entityAdded(ref: "scene:10", name: "X", kind: nil))
        await store.apply(event: .entityAdded(ref: "scene:11", name: "Y", kind: nil))
        await store.apply(event: .editApplied(editID: "e10", summary: "edit", revision: 1))
        let entries = await store.allEntries()
        #expect(entries.count == 2)
        let hasEdit = entries.contains { $0.kind == .entityEdit }
        #expect(hasEdit)
    }

    @Test("store.lookup(subject:) filters by subject")
    func storeLookupBySubject() async throws {
        let store = try ContextMemoryStore()
        await store.apply(event: .entityAdded(ref: "scene:5", name: "Light", kind: "light"))
        await store.apply(event: .entityAdded(ref: "scene:6", name: "Cam", kind: "camera"))
        let results = await store.lookup(subject: "scene:5")
        #expect(results.count == 1)
        #expect(results[0].payload["name"] == "Light")
    }

    @Test("store.lookup(kind:) filters by kind")
    func storeLookupByKind() async throws {
        let store = try ContextMemoryStore()
        await store.apply(event: .entityAdded(ref: "scene:7", name: "Mesh", kind: nil))
        await store.apply(event: .editApplied(editID: "e5", summary: "scaled", revision: 3))
        let annotations = await store.lookup(kind: .sceneAnnotation)
        let edits       = await store.lookup(kind: .entityEdit)
        #expect(annotations.count == 1)
        #expect(edits.count == 1)
    }

    @Test("store.entry(id:) returns entry or nil")
    func storeEntryByID() async throws {
        let store = try ContextMemoryStore()
        await store.apply(event: .editApplied(editID: "e6", summary: "deleted", revision: 4))
        let found   = await store.entry(id: "edit:e6")
        let missing = await store.entry(id: "nonexistent")
        #expect(found != nil)
        #expect(missing == nil)
    }

    @Test("symbolicView respects budget cap")
    func symbolicViewRespectsBudget() async throws {
        let store = try ContextMemoryStore(capacity: 100)
        for i in 0..<10 {
            await store.apply(event: .entityAdded(ref: "scene:\(i)", name: "E\(i)", kind: nil))
        }
        let view = await store.symbolicView(budget: 3)
        #expect(view.count == 3)
    }

    @Test("symbolicView entries contain required keys")
    func symbolicViewContainsRequiredKeys() async throws {
        let store = try ContextMemoryStore()
        await store.apply(event: .entityAdded(ref: "scene:20", name: "Rock", kind: "mesh"))
        let view = await store.symbolicView(budget: 10)
        #expect(view.count == 1)
        let dict = view[0]
        #expect(dict["id"] != nil)
        #expect(dict["kind"] != nil)
        #expect(dict["subject"] != nil)
        #expect(dict["name"] == "Rock")
    }

    @Test("store.upsert inserts or updates an entry directly")
    func storeManualUpsert() async throws {
        let store = try ContextMemoryStore()
        let entry = ContextEntry(id: "pref:test", kind: .userPreference,
                                 subject: "session", payload: ["key": "val"], importance: 0.7)
        await store.upsert(entry)
        let found = await store.entry(id: "pref:test")
        #expect(found?.kind == .userPreference)
        #expect(found?.payload["key"] == "val")
    }

    @Test("store.remove deletes entry by id")
    func storeManualRemove() async throws {
        let store = try ContextMemoryStore()
        await store.apply(event: .entityAdded(ref: "scene:50", name: "X", kind: nil))
        let before = await store.entry(id: "entity_added:scene:50")
        #expect(before != nil)
        await store.remove(id: "entity_added:scene:50")
        let after = await store.entry(id: "entity_added:scene:50")
        #expect(after == nil)
    }

    @Test("store.upsert respects capacity eviction")
    func storeUpsertRespectsCapacity() async throws {
        let store = try ContextMemoryStore(capacity: 2)
        await store.upsert(ContextEntry(id: "a", kind: .userPreference, subject: "s",
                                        payload: [:], importance: 0.1))
        await store.upsert(ContextEntry(id: "b", kind: .userPreference, subject: "s",
                                        payload: [:], importance: 0.2))
        await store.upsert(ContextEntry(id: "c", kind: .userPreference, subject: "s",
                                        payload: [:], importance: 0.9))
        let entries = await store.allEntries()
        #expect(entries.count == 2)
        // "a" (lowest importance) should have been evicted
        #expect(await store.entry(id: "a") == nil)
        #expect(await store.entry(id: "c") != nil)
    }

    @Test("flush and reload round-trip preserves entries")
    func flushAndReloadRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("context_memory_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store1 = try ContextMemoryStore(storageURL: url)
        await store1.apply(event: .entityAdded(ref: "scene:30", name: "Tree", kind: "mesh"))
        await store1.apply(event: .editApplied(editID: "e20", summary: "painted", revision: 5))
        try await store1.flush()

        let store2 = try ContextMemoryStore(storageURL: url)
        let entries = await store2.allEntries()
        #expect(entries.count == 2)
        #expect(entries.contains { $0.id == "entity_added:scene:30" })
        #expect(entries.contains { $0.id == "edit:e20" })
    }
}
