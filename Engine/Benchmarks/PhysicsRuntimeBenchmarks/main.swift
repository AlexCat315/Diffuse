import Foundation
import SceneRuntime
import SIMDCompat

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct Configuration {
    var bodyCount: Int
    var warmupFrames: Int
    var sampleFrames: Int

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        bodyCount = Int(environment["GUAVA_PHYSICS_BODIES"] ?? "") ?? 10_000
        warmupFrames = Int(environment["GUAVA_PHYSICS_WARMUP_FRAMES"] ?? "") ?? 120
        sampleFrames = Int(environment["GUAVA_PHYSICS_SAMPLE_FRAMES"] ?? "") ?? 600
    }
}

private func makeBenchmarkScene(bodyCount: Int) -> SceneRuntime {
    var runtime = SceneRuntime()
    runtime.setPhysicsSettings(
        PhysicsSettingsResource(
            simulationMode: .play,
            backendKind: .jolt,
            fixedTimeStepSeconds: 1.0 / 60.0,
            maxSubstepsPerFrame: 1,
            allowSleep: false,
            collisionSteps: 1
        )
    )

    let floor = runtime.createEntity()
    _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, -0.5, 0)), for: floor)
    _ = runtime.setComponent(
        Collider(shape: .box(halfExtents: SIMD3<Float>(100, 0.5, 100), center: .zero)),
        for: floor
    )

    let columns = max(1, Int(ceil(sqrt(Double(bodyCount)))))
    for index in 0..<bodyCount {
        let x = Float(index % columns) * 1.1 - Float(columns) * 0.55
        let z = Float(index / columns) * 1.1 - Float(columns) * 0.55
        let y = 1 + Float(index % 5) * 1.1
        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(x, y, z)), for: entity)
        _ = runtime.setComponent(RigidBody(motionType: .dynamic, mass: 1, allowSleep: false), for: entity)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(repeating: 0.5), center: .zero)),
            for: entity
        )
    }
    return runtime
}

private func percentile(_ sorted: [UInt64], _ fraction: Double) -> UInt64 {
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(Int(Double(sorted.count - 1) * fraction), sorted.count - 1)]
}

private func milliseconds(_ nanoseconds: UInt64) -> String {
    String(format: "%.3f", Double(nanoseconds) / 1_000_000)
}

private func peakResidentBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    #if os(macOS)
    return UInt64(usage.ru_maxrss)
    #else
    return UInt64(usage.ru_maxrss) * 1024
    #endif
}

private let configuration = Configuration()
var runtime = makeBenchmarkScene(bodyCount: configuration.bodyCount)
for frame in 0..<configuration.warmupFrames {
    _ = runtime.tick(deltaTime: 1.0 / 60.0, frameIndex: UInt64(frame))
}

var stepSamples: [UInt64] = []
var syncSamples: [UInt64] = []
var contactTotal = 0
var activeBodyPeak = 0
var droppedSteps = 0
stepSamples.reserveCapacity(configuration.sampleFrames)
syncSamples.reserveCapacity(configuration.sampleFrames)

for offset in 0..<configuration.sampleFrames {
    let frame = configuration.warmupFrames + offset
    let report = runtime.tick(deltaTime: 1.0 / 60.0, frameIndex: UInt64(frame))
    stepSamples.append(report.physicsStepNanoseconds)
    syncSamples.append(report.physicsSynchronizationNanoseconds)
    contactTotal += report.physicsContactCount
    activeBodyPeak = max(activeBodyPeak, runtime.physicsFrameState.activeBodyCount)
    droppedSteps += report.physicsDroppedStepCount
}

let sortedSteps = stepSamples.sorted()
let sortedSync = syncSamples.sorted()
print("PhysicsRuntimeBenchmarks bodies=\(configuration.bodyCount) frames=\(configuration.sampleFrames)")
print("step_ms p50=\(milliseconds(percentile(sortedSteps, 0.50))) p95=\(milliseconds(percentile(sortedSteps, 0.95))) p99=\(milliseconds(percentile(sortedSteps, 0.99)))")
print("sync_ms p50=\(milliseconds(percentile(sortedSync, 0.50))) p95=\(milliseconds(percentile(sortedSync, 0.95))) p99=\(milliseconds(percentile(sortedSync, 0.99)))")
print("contacts_total=\(contactTotal) active_body_peak=\(activeBodyPeak) dropped_steps=\(droppedSteps) peak_rss_bytes=\(peakResidentBytes())")

if configuration.bodyCount >= 10_000,
   percentile(sortedSteps, 0.95) > 16_670_000 || droppedSteps > 0 {
    fputs("Physics benchmark gate failed: 10k p95 exceeds 16.67 ms or fixed steps were dropped.\n", stderr)
    exit(1)
}
