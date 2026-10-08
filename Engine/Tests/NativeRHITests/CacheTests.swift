// NativeRHITests — PipelineLayoutCache (full-value keying) and BindingSetCache
// (hit/miss stats, bounded LRU eviction).

import XCTest
@testable import NativeRHI

final class PipelineLayoutCacheTests: XCTestCase {
    func testLayoutKeyedByFullIDList() {
        let cache = PipelineLayoutCache()
        cache.insert(10, for: PipelineInterfaceKey(setLayouts: [1, 2], pushConstants: []))
        cache.insert(11, for: PipelineInterfaceKey(setLayouts: [2, 1], pushConstants: []))

        // Order matters: [1,2] and [2,1] are distinct layouts.
        XCTAssertEqual(cache.layout(for: PipelineInterfaceKey(setLayouts: [1, 2], pushConstants: [])), 10)
        XCTAssertEqual(cache.layout(for: PipelineInterfaceKey(setLayouts: [2, 1], pushConstants: [])), 11)
    }

    func testUnknownLayoutReturnsNil() {
        let cache = PipelineLayoutCache()
        XCTAssertNil(cache.layout(for: PipelineInterfaceKey(setLayouts: [9], pushConstants: [])))
    }

    func testReInsertingSameLayoutOverwrites() {
        let cache = PipelineLayoutCache()
        cache.insert(10, for: PipelineInterfaceKey(setLayouts: [1], pushConstants: []))
        cache.insert(12, for: PipelineInterfaceKey(setLayouts: [1], pushConstants: []))
        XCTAssertEqual(cache.layout(for: PipelineInterfaceKey(setLayouts: [1], pushConstants: [])), 12)
    }
}

final class BindingSetCacheTests: XCTestCase {
    private func makeEntry(_ slot: UInt32) -> BindingSetEntry {
        BindingSetEntry(slot: slot, resource: .uniformBuffer(buffer: Buffer(id: slot + 1)))
    }

    func testMissThenHit() {
        let cache = BindingSetCache()
        let entries = [makeEntry(0)]

        XCTAssertNil(cache.existing(layoutID: 5, entries: entries))
        XCTAssertEqual(cache.stats.misses, 1)

        cache.insert(100, layoutID: 5, entries: entries)
        XCTAssertEqual(cache.existing(layoutID: 5, entries: entries), 100)
        XCTAssertEqual(cache.stats.hits, 1)
    }

    func testDifferentLayoutsDoNotAlias() {
        let cache = BindingSetCache()
        let entries = [makeEntry(0)]
        cache.insert(100, layoutID: 5, entries: entries)
        cache.insert(101, layoutID: 6, entries: entries)

        XCTAssertEqual(cache.existing(layoutID: 5, entries: entries), 100)
        XCTAssertEqual(cache.existing(layoutID: 6, entries: entries), 101)
    }

    func testEvictionDoesNotTriggerBeforeCapacity() {
        let cache = BindingSetCache()
        XCTAssertNil(cache.evictIfFull())
        XCTAssertEqual(cache.stats.evictions, 0)
    }

    func testEvictionWhenFullReturnsLRUHandle() {
        let cache = BindingSetCache()
        // Fill to capacity.
        for index in 0..<BindingSetCache.capacity {
            let entries = [makeEntry(UInt32(index))]
            cache.insert(UInt32(index + 1), layoutID: UInt32(index + 1), entries: entries)
        }
        // Entry 0 is the least recently used (never re-read).
        let evicted = cache.evictIfFull()
        XCTAssertEqual(evicted, 1)
        XCTAssertEqual(cache.stats.evictions, 1)
    }
}
