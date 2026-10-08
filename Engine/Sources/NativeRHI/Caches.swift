// NativeRHI — value-keyed caches and O(1) LRU.
//
// The Zig prototype keyed its pipeline-layout and binding-set caches by a bare
// Wyhash value with no collision handling, and its LRU eviction was O(n)
// (orderedRemove(0)). The Swift port keys caches by the *full* value (the
// Swift dictionary resolves hash collisions through equality), and the LRU is a
// doubly-linked list giving O(1) touch/insert/evict.

import Foundation

// MARK: - O(1) LRU map

final class LRUMap<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var prev: Node?
        var next: Node?

        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    private var storage: [Key: Node] = [:]
    private var head: Node? // most recently used
    private var tail: Node? // least recently used
    private(set) var count: Int = 0

    func value(forKey key: Key) -> Value? {
        guard let node = storage[key] else { return nil }
        moveToHead(node)
        return node.value
    }

    func setValue(_ value: Value, forKey key: Key) {
        if let node = storage[key] {
            node.value = value
            moveToHead(node)
        } else {
            let node = Node(key: key, value: value)
            storage[key] = node
            addToHead(node)
            count += 1
        }
    }

    @discardableResult
    func removeValue(forKey key: Key) -> Value? {
        guard let node = storage[key] else { return nil }
        detach(node)
        storage[key] = nil
        count -= 1
        return node.value
    }

    @discardableResult
    func evictLeastRecentlyUsed() -> (key: Key, value: Value)? {
        guard let victim = tail else { return nil }
        detach(victim)
        storage[victim.key] = nil
        count -= 1
        return (victim.key, victim.value)
    }

    func removeAll(keepingCapacity keepCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepCapacity)
        head = nil
        tail = nil
        count = 0
    }

    private func addToHead(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func detach(_ node: Node) {
        if let prev = node.prev {
            prev.next = node.next
        } else {
            head = node.next
        }
        if let next = node.next {
            next.prev = node.prev
        } else {
            tail = node.prev
        }
        node.prev = nil
        node.next = nil
    }

    private func moveToHead(_ node: Node) {
        detach(node)
        addToHead(node)
    }
}

// MARK: - Cache statistics

public struct CacheStats: Sendable, Equatable {
    public var hits: UInt64
    public var misses: UInt64
    public var evictions: UInt64

    public init(hits: UInt64 = 0, misses: UInt64 = 0, evictions: UInt64 = 0) {
        self.hits = hits
        self.misses = misses
        self.evictions = evictions
    }

    public var totalLookups: UInt64 { hits + misses }

    public var hitRate: Double {
        let total = hits + misses
        guard total > 0 else { return 0 }
        return Double(hits) / Double(total)
    }

    /// Counts since `previous`, saturating at zero for each field.
    public func delta(since previous: CacheStats) -> CacheStats {
        CacheStats(
            hits: hits >= previous.hits ? hits - previous.hits : 0,
            misses: misses >= previous.misses ? misses - previous.misses : 0,
            evictions: evictions >= previous.evictions ? evictions - previous.evictions : 0
        )
    }
}

// MARK: - Pipeline layout cache

/// Maps the ordered set of binding-layout IDs to a pipeline-layout handle.
/// Keyed by the full ID list, so distinct layouts never collide.
final class PipelineLayoutCache {
    private var byInterface: [PipelineInterfaceKey: UInt32] = [:]

    func layout(for key: PipelineInterfaceKey) -> UInt32? {
        byInterface[key]
    }

    func insert(_ handleID: UInt32, for key: PipelineInterfaceKey) {
        byInterface[key] = handleID
    }
}

// MARK: - Binding set cache

struct BindingSetCacheKey: Hashable {
    var layoutID: UInt32
    var entries: [BindingSetEntry]
}

/// Bounded LRU cache of resolved binding sets. Lookups record hit/miss stats;
/// when full, the least recently used set is evicted and its handle returned
/// for teardown.
final class BindingSetCache {
    static let capacity = 1024

    private let lru = LRUMap<BindingSetCacheKey, UInt32>()
    private(set) var stats = CacheStats()

    var count: Int { lru.count }

    func existing(layoutID: UInt32, entries: [BindingSetEntry]) -> UInt32? {
        let key = BindingSetCacheKey(layoutID: layoutID, entries: entries)
        if let id = lru.value(forKey: key) {
            stats.hits += 1
            return id
        }
        stats.misses += 1
        return nil
    }

    func insert(_ handleID: UInt32, layoutID: UInt32, entries: [BindingSetEntry]) {
        lru.setValue(handleID, forKey: BindingSetCacheKey(layoutID: layoutID, entries: entries))
    }

    @discardableResult
    func evictIfFull() -> UInt32? {
        guard lru.count >= BindingSetCache.capacity else { return nil }
        let evicted = lru.evictLeastRecentlyUsed()
        stats.evictions += 1
        return evicted?.value
    }

    /// Removes a known set entry. Used when the user explicitly destroys a
    /// binding set; the caller already holds the layout ID and entries.
    @discardableResult
    func remove(layoutID: UInt32, entries: [BindingSetEntry]) -> UInt32? {
        lru.removeValue(forKey: BindingSetCacheKey(layoutID: layoutID, entries: entries))
    }

    func resetStats() { stats = CacheStats() }
}

// MARK: - Grouped device caches

/// All frontend-owned binding/pipeline bookkeeping, grouped so the public
/// `Device` stays small (single responsibility per group).
final class DeviceCaches {
    /// Binding-layout handle ID → its layout entries.
    private(set) var bindingLayouts: [UInt32: [BindingLayoutEntry]] = [:]
    /// Binding-set handle ID → the layout it was built against.
    private(set) var bindingSetOwners: [UInt32: UInt32] = [:]
    /// Pipeline-layout handle ID → the ordered set of binding-layout IDs.
    private(set) var pipelineLayoutDefinitions: [UInt32: [UInt32]] = [:]

    let pipelineLayouts = PipelineLayoutCache()
    let bindingSets = BindingSetCache()

    // Binding layout

    func storeBindingLayout(_ id: UInt32, entries: [BindingLayoutEntry]) {
        bindingLayouts[id] = entries
    }

    func bindingLayoutEntries(_ id: UInt32) -> [BindingLayoutEntry]? {
        bindingLayouts[id]
    }

    // Binding set

    func storeBindingSet(_ id: UInt32, layoutID: UInt32) {
        bindingSetOwners[id] = layoutID
    }

    func bindingSetLayoutID(_ id: UInt32) -> UInt32? {
        bindingSetOwners[id]
    }

    @discardableResult
    func removeBindingSetOwner(_ id: UInt32) -> UInt32? {
        bindingSetOwners.removeValue(forKey: id)
    }

    // Pipeline layout

    func storePipelineLayoutDefinition(_ id: UInt32, setLayouts: [UInt32]) {
        pipelineLayoutDefinitions[id] = setLayouts
    }

    func pipelineLayoutDefinition(_ id: UInt32) -> [UInt32]? {
        pipelineLayoutDefinitions[id]
    }
}
