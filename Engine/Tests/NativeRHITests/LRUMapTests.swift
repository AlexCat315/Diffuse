// NativeRHITests — O(1) LRU map ordering, eviction, and cache stats.

import XCTest
@testable import NativeRHI

final class LRUMapTests: XCTestCase {
    func testInsertAndRead() {
        let lru = LRUMap<Int, String>()
        lru.setValue("a", forKey: 1)
        XCTAssertEqual(lru.value(forKey: 1), "a")
        XCTAssertEqual(lru.count, 1)
    }

    func testEvictionSelectsLeastRecentlyUsed() {
        let lru = LRUMap<Int, String>()
        lru.setValue("a", forKey: 1)
        lru.setValue("b", forKey: 2)
        lru.setValue("c", forKey: 3)

        // Touch key 1 so key 2 becomes the least recently used.
        _ = lru.value(forKey: 1)

        let evicted = lru.evictLeastRecentlyUsed()
        XCTAssertEqual(evicted?.key, 2)
        XCTAssertEqual(evicted?.value, "b")
        XCTAssertEqual(lru.count, 2)
        XCTAssertNil(lru.value(forKey: 2))
    }

    func testEvictionOrderFollowsInsertionWithoutReads() {
        let lru = LRUMap<Int, String>()
        lru.setValue("a", forKey: 1)
        lru.setValue("b", forKey: 2)
        XCTAssertEqual(lru.evictLeastRecentlyUsed()?.key, 1)
        XCTAssertEqual(lru.evictLeastRecentlyUsed()?.key, 2)
        XCTAssertNil(lru.evictLeastRecentlyUsed())
    }

    func testUpdateExistingKeyDoesNotGrowCount() {
        let lru = LRUMap<Int, String>()
        lru.setValue("a", forKey: 1)
        lru.setValue("z", forKey: 1)
        XCTAssertEqual(lru.count, 1)
        XCTAssertEqual(lru.value(forKey: 1), "z")
    }

    func testRemoveValue() {
        let lru = LRUMap<Int, String>()
        lru.setValue("a", forKey: 1)
        XCTAssertEqual(lru.removeValue(forKey: 1), "a")
        XCTAssertEqual(lru.count, 0)
        XCTAssertNil(lru.value(forKey: 1))
    }

    func testRemoveAllResetsOrdering() {
        let lru = LRUMap<Int, String>()
        lru.setValue("a", forKey: 1)
        lru.setValue("b", forKey: 2)
        lru.removeAll()
        XCTAssertEqual(lru.count, 0)
        XCTAssertNil(lru.evictLeastRecentlyUsed())
    }
}

final class CacheStatsTests: XCTestCase {
    func testHitRate() {
        let stats = CacheStats(hits: 3, misses: 1)
        XCTAssertEqual(stats.totalLookups, 4)
        XCTAssertEqual(stats.hitRate, 0.75, accuracy: 1e-9)
    }

    func testHitRateWithNoLookupsIsZero() {
        XCTAssertEqual(CacheStats().hitRate, 0)
    }

    func testDeltaSinceEarlierSnapshot() {
        let earlier = CacheStats(hits: 2, misses: 1, evictions: 0)
        let later = CacheStats(hits: 5, misses: 4, evictions: 2)
        let delta = later.delta(since: earlier)
        XCTAssertEqual(delta, CacheStats(hits: 3, misses: 3, evictions: 2))
    }
}
