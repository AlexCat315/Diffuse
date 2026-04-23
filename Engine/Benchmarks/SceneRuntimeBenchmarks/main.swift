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

private func benchmarkRaycast(runtime: SceneRuntime, queryCount: Int) {
    let scratch = SpatialQueryScratch()
    var nodeVisits = 0
    var leafTests = 0
    var narrowPhaseTests = 0
    let start = DispatchTime.now().uptimeNanoseconds

    for i in 0..<queryCount {
        let origin = SIMD3<Float>(Float(i % 100) * 0.8 - 20, Float((i / 100) % 50) * 0.8 - 10, -50)
        let direction = SIMD3<Float>(0.1, 0.05, 1)
        let result = runtime.physicsRaycastWithStats(
            PhysicsRaycastQuery(origin: origin, direction: direction, maxDistance: 300),
            scratch: scratch
        )
        nodeVisits += result.stats.nodeVisits
        leafTests += result.stats.leafTests
        narrowPhaseTests += result.stats.narrowPhaseTests
    }

    let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    let elapsedText = String(format: "%.2f", elapsedMS)
    print("[Raycast] queries=\(queryCount) elapsed_ms=\(elapsedText) avg_node_visits=\(nodeVisits / max(queryCount, 1)) avg_leaf_tests=\(leafTests / max(queryCount, 1)) avg_narrow_phase=\(narrowPhaseTests / max(queryCount, 1))")
}

private func benchmarkOverlap(runtime: SceneRuntime, queryCount: Int) {
    let scratch = SpatialQueryScratch()
    var nodeVisits = 0
    var leafTests = 0
    var narrowPhaseTests = 0
    var totalHits = 0
    let start = DispatchTime.now().uptimeNanoseconds

    for i in 0..<queryCount {
        let center = SIMD3<Float>(Float(i % 100) * 1.0, Float((i / 100) % 50) * 1.0, 0)
        let result = runtime.physicsOverlapAABBWithStats(
            PhysicsOverlapAABBQuery(bounds: SpatialAABB(center: center, halfExtents: SIMD3<Float>(2, 2, 2))),
            scratch: scratch
        )
        totalHits += result.hits.count
        nodeVisits += result.stats.nodeVisits
        leafTests += result.stats.leafTests
        narrowPhaseTests += result.stats.narrowPhaseTests
    }

    let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    let elapsedText = String(format: "%.2f", elapsedMS)
    print("[Overlap] queries=\(queryCount) elapsed_ms=\(elapsedText) avg_hits=\(totalHits / max(queryCount, 1)) avg_node_visits=\(nodeVisits / max(queryCount, 1)) avg_leaf_tests=\(leafTests / max(queryCount, 1)) avg_narrow_phase=\(narrowPhaseTests / max(queryCount, 1))")
}

private func benchmarkSweep(runtime: SceneRuntime, queryCount: Int) {
    let scratch = SpatialQueryScratch()
    var nodeVisits = 0
    var leafTests = 0
    var narrowPhaseTests = 0
    var hitCount = 0
    let start = DispatchTime.now().uptimeNanoseconds

    for i in 0..<queryCount {
        let center = SIMD3<Float>(Float(i % 100) * 0.9 - 10, Float((i / 100) % 50) * 0.9 - 5, -10)
        let result = runtime.physicsSweepAABBWithStats(
            PhysicsSweepAABBQuery(bounds: SpatialAABB(center: center, halfExtents: SIMD3<Float>(0.3, 0.3, 0.3)),
                                  translation: SIMD3<Float>(0, 0, 60)),
            scratch: scratch
        )
        if result.hit != nil {
            hitCount += 1
        }
        nodeVisits += result.stats.nodeVisits
        leafTests += result.stats.leafTests
        narrowPhaseTests += result.stats.narrowPhaseTests
    }

    let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    let elapsedText = String(format: "%.2f", elapsedMS)
    print("[Sweep] queries=\(queryCount) elapsed_ms=\(elapsedText) hit_count=\(hitCount) avg_node_visits=\(nodeVisits / max(queryCount, 1)) avg_leaf_tests=\(leafTests / max(queryCount, 1)) avg_narrow_phase=\(narrowPhaseTests / max(queryCount, 1))")
}

let config = BenchmarkConfig()
let runtime = makeRuntime(entityCount: config.entityCount)
print("SceneRuntimeBenchmarks entity_count=\(config.entityCount) query_count=\(config.queryCount)")
benchmarkRaycast(runtime: runtime, queryCount: config.queryCount)
benchmarkOverlap(runtime: runtime, queryCount: config.queryCount)
benchmarkSweep(runtime: runtime, queryCount: config.queryCount)
