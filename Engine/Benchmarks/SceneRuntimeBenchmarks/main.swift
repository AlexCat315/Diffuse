import Foundation
import SceneRuntime
import simd

struct BenchmarkConfig {
    var entityCount: Int = 5000
    var queryCount: Int = 2000
}

private func makeRuntime(entityCount: Int) -> SceneRuntime {
    var runtime = SceneRuntime()
    runtime.setSpatialIndexBuildSettings(SpatialIndexBuildSettings(mode: .adaptive))

    for index in 0..<entityCount {
        let entity = runtime.createEntity()
        let x = Float(index % 100) * 1.5
        let y = Float((index / 100) % 50) * 1.1
        let z = Float(index / 5000) * 3
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(x, y, z)), for: entity)

        if index % 3 == 0 {
            _ = runtime.setComponent(Collider(shape: .sphere(radius: 0.5, center: .zero)), for: entity)
        } else {
            _ = runtime.setComponent(
                Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero)),
                for: entity
            )
        }
    }

    _ = runtime.tick()
    return runtime
}

// Returns (p50, p95, p99) in nanoseconds from a pre-sorted array.
private func percentiles(_ sorted: [UInt64]) -> (p50: UInt64, p95: UInt64, p99: UInt64) {
    guard !sorted.isEmpty else { return (0, 0, 0) }
    let n = sorted.count
    return (
        sorted[n / 2],
        sorted[min(Int(Double(n) * 0.95), n - 1)],
        sorted[min(Int(Double(n) * 0.99), n - 1)]
    )
}

private func fmtMs(_ ns: Double) -> String { String(format: "%.2f", ns / 1_000_000) }
private func fmtUs(_ ns: UInt64) -> String { String(format: "%.1f", Double(ns) / 1_000) }
private func fmtAvg(_ total: Int, _ count: Int) -> String {
    String(format: "%.2f", count > 0 ? Double(total) / Double(count) : 0)
}

private func benchmarkRaycast(runtime: SceneRuntime, queryCount: Int) {
    let scratch = SpatialQueryScratch()  // reused across all queries
    var nodeVisits = 0
    var leafTests = 0
    var narrowPhaseTests = 0
    var perQueryNs = [UInt64]()
    perQueryNs.reserveCapacity(queryCount)

    for i in 0..<queryCount {
        let origin = SIMD3<Float>(Float(i % 100) * 0.8 - 20, Float((i / 100) % 50) * 0.8 - 10, -50)
        let direction = SIMD3<Float>(0.1, 0.05, 1)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let result = runtime.physicsRaycastWithStats(
            PhysicsRaycastQuery(origin: origin, direction: direction, maxDistance: 300),
            scratch: scratch
        )
        perQueryNs.append(DispatchTime.now().uptimeNanoseconds - t0)
        nodeVisits += result.stats.nodeVisits
        leafTests += result.stats.leafTests
        narrowPhaseTests += result.stats.narrowPhaseTests
    }

    let totalNs = perQueryNs.reduce(0, +)
    let sorted = perQueryNs.sorted()
    let (p50, p95, p99) = percentiles(sorted)
    print("[Raycast] queries=\(queryCount) elapsed_ms=\(fmtMs(Double(totalNs)))" +
          " avg_node_visits=\(fmtAvg(nodeVisits, queryCount))" +
          " avg_leaf_tests=\(fmtAvg(leafTests, queryCount))" +
          " avg_narrow_phase=\(fmtAvg(narrowPhaseTests, queryCount))" +
          " p50=\(fmtUs(p50))µs p95=\(fmtUs(p95))µs p99=\(fmtUs(p99))µs")
}

private func benchmarkOverlap(runtime: SceneRuntime, queryCount: Int, maxResults: Int = .max) {
    let scratch = SpatialQueryScratch()  // reused across all queries — no per-query allocation
    var nodeVisits = 0
    var leafTests = 0
    var narrowPhaseTests = 0
    var totalHits = 0
    var perQueryNs = [UInt64]()
    perQueryNs.reserveCapacity(queryCount)

    for i in 0..<queryCount {
        let center = SIMD3<Float>(Float(i % 100) * 1.0, Float((i / 100) % 50) * 1.0, 0)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let result = runtime.physicsOverlapAABBWithStats(
            PhysicsOverlapAABBQuery(
                bounds: SpatialAABB(center: center, halfExtents: SIMD3<Float>(2, 2, 2)),
                maxResults: maxResults
            ),
            scratch: scratch
        )
        perQueryNs.append(DispatchTime.now().uptimeNanoseconds - t0)
        totalHits += result.hits.count
        nodeVisits += result.stats.nodeVisits
        leafTests += result.stats.leafTests
        narrowPhaseTests += result.stats.narrowPhaseTests
    }

    let totalNs = perQueryNs.reduce(0, +)
    let sorted = perQueryNs.sorted()
    let (p50, p95, p99) = percentiles(sorted)
    let label = maxResults == .max ? "[Overlap]" : "[Overlap maxResults=\(maxResults)]"
    print("\(label) queries=\(queryCount) elapsed_ms=\(fmtMs(Double(totalNs)))" +
          " avg_hits=\(fmtAvg(totalHits, queryCount))" +
          " avg_node_visits=\(fmtAvg(nodeVisits, queryCount))" +
          " avg_leaf_tests=\(fmtAvg(leafTests, queryCount))" +
          " avg_narrow_phase=\(fmtAvg(narrowPhaseTests, queryCount))" +
          " p50=\(fmtUs(p50))µs p95=\(fmtUs(p95))µs p99=\(fmtUs(p99))µs")
}

private func benchmarkSweep(runtime: SceneRuntime, queryCount: Int) {
    let scratch = SpatialQueryScratch()  // reused across all queries
    var nodeVisits = 0
    var leafTests = 0
    var narrowPhaseTests = 0
    var hitCount = 0
    var perQueryNs = [UInt64]()
    perQueryNs.reserveCapacity(queryCount)

    for i in 0..<queryCount {
        let center = SIMD3<Float>(Float(i % 100) * 0.9 - 10, Float((i / 100) % 50) * 0.9 - 5, -10)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let result = runtime.physicsSweepAABBWithStats(
            PhysicsSweepAABBQuery(bounds: SpatialAABB(center: center, halfExtents: SIMD3<Float>(0.3, 0.3, 0.3)),
                                  translation: SIMD3<Float>(0, 0, 60)),
            scratch: scratch
        )
        perQueryNs.append(DispatchTime.now().uptimeNanoseconds - t0)
        if result.hit != nil { hitCount += 1 }
        nodeVisits += result.stats.nodeVisits
        leafTests += result.stats.leafTests
        narrowPhaseTests += result.stats.narrowPhaseTests
    }

    let totalNs = perQueryNs.reduce(0, +)
    let sorted = perQueryNs.sorted()
    let (p50, p95, p99) = percentiles(sorted)
    print("[Sweep] queries=\(queryCount) elapsed_ms=\(fmtMs(Double(totalNs)))" +
          " hit_count=\(hitCount)" +
          " avg_node_visits=\(fmtAvg(nodeVisits, queryCount))" +
          " avg_leaf_tests=\(fmtAvg(leafTests, queryCount))" +
          " avg_narrow_phase=\(fmtAvg(narrowPhaseTests, queryCount))" +
          " p50=\(fmtUs(p50))µs p95=\(fmtUs(p95))µs p99=\(fmtUs(p99))µs")
}

let config = BenchmarkConfig()
let runtime = makeRuntime(entityCount: config.entityCount)
print("SceneRuntimeBenchmarks entity_count=\(config.entityCount) query_count=\(config.queryCount)")
benchmarkRaycast(runtime: runtime, queryCount: config.queryCount)
benchmarkOverlap(runtime: runtime, queryCount: config.queryCount)
benchmarkOverlap(runtime: runtime, queryCount: config.queryCount, maxResults: 4)
benchmarkSweep(runtime: runtime, queryCount: config.queryCount)
