import Foundation
import SceneRuntime
import SIMDCompat

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct Configuration {
    enum Scenario: String {
        case activeGrid = "active-grid"
        case denseContact = "dense-contact"
    }

    var scenario: Scenario
    var bodyCount: Int
    var warmupFrames: Int
    var sampleFrames: Int
    var workerThreadCount: Int

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        scenario = Scenario(rawValue: environment["GUAVA_PHYSICS_SCENARIO"] ?? "") ?? .activeGrid
        let defaultBodyCount = scenario == .denseContact ? 2_000 : 10_000
        bodyCount = Int(environment["GUAVA_PHYSICS_BODIES"] ?? "") ?? defaultBodyCount
        warmupFrames = Int(environment["GUAVA_PHYSICS_WARMUP_FRAMES"] ?? "") ?? 120
        sampleFrames = Int(environment["GUAVA_PHYSICS_SAMPLE_FRAMES"] ?? "") ?? 600
        workerThreadCount = Int(environment["GUAVA_PHYSICS_WORKERS"] ?? "") ?? 0
    }
}

private func makeBenchmarkScene(configuration: Configuration) -> SceneRuntime {
    var runtime = SceneRuntime()
    runtime.setPhysicsSettings(
        PhysicsSettingsResource(
            simulationMode: .play,
            backendKind: .jolt,
            gravity: configuration.scenario == .activeGrid ? .zero : SIMD3<Float>(0, -9.81, 0),
            fixedTimeStepSeconds: 1.0 / 60.0,
            maxSubstepsPerFrame: 1,
            allowSleep: false,
            collisionSteps: 1,
            capacity: PhysicsCapacitySettings(
                maxBodies: max(16_384, configuration.bodyCount + 16),
                maxBodyPairs: configuration.scenario == .denseContact ? 131_072 : 65_536,
                maxContactConstraints: configuration.scenario == .denseContact ? 32_768 : 16_384,
                tempAllocatorBytes: 64 * 1_024 * 1_024,
                workerThreadCount: configuration.workerThreadCount
            )
        )
    )

    if configuration.scenario == .denseContact {
        let floor = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, -0.5, 0)), for: floor)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(100, 0.5, 100), center: .zero)),
            for: floor
        )
    }

    let activeColumns = max(1, Int(ceil(sqrt(Double(configuration.bodyCount)))))
    let denseColumns = 20
    for index in 0..<configuration.bodyCount {
        let position: SIMD3<Float>
        switch configuration.scenario {
        case .activeGrid:
            position = SIMD3<Float>(
                Float(index % activeColumns) * 1.1 - Float(activeColumns) * 0.55,
                1 + Float(index % 5) * 1.1,
                Float(index / activeColumns) * 1.1 - Float(activeColumns) * 0.55
            )
        case .denseContact:
            let layerSize = denseColumns * denseColumns
            position = SIMD3<Float>(
                Float(index % denseColumns) * 0.92 - Float(denseColumns) * 0.46,
                0.5 + Float(index / layerSize) * 0.92,
                Float((index / denseColumns) % denseColumns) * 0.92 - Float(denseColumns) * 0.46
            )
        }
        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: position), for: entity)
        let velocity = configuration.scenario == .activeGrid
            ? SIMD3<Float>(0.25, 0.1, 0.15)
            : .zero
        _ = runtime.setComponent(RigidBody(
            motionType: .dynamic,
            mass: 1,
            linearVelocity: velocity,
            allowSleep: false
        ), for: entity)
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
var runtime = makeBenchmarkScene(configuration: configuration)
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
print("PhysicsRuntimeBenchmarks scenario=\(configuration.scenario.rawValue) bodies=\(configuration.bodyCount) frames=\(configuration.sampleFrames)")
print("step_ms p50=\(milliseconds(percentile(sortedSteps, 0.50))) p95=\(milliseconds(percentile(sortedSteps, 0.95))) p99=\(milliseconds(percentile(sortedSteps, 0.99)))")
print("sync_ms p50=\(milliseconds(percentile(sortedSync, 0.50))) p95=\(milliseconds(percentile(sortedSync, 0.95))) p99=\(milliseconds(percentile(sortedSync, 0.99)))")
print("contacts_total=\(contactTotal) active_body_peak=\(activeBodyPeak) dropped_steps=\(droppedSteps) peak_rss_bytes=\(peakResidentBytes())")

if configuration.scenario == .activeGrid,
   configuration.bodyCount >= 10_000,
   percentile(sortedSteps, 0.95) > 16_670_000 || droppedSteps > 0 {
    fputs("Physics benchmark gate failed: 10k p95 exceeds 16.67 ms or fixed steps were dropped.\n", stderr)
    exit(1)
}
if configuration.scenario == .denseContact,
   configuration.bodyCount >= 2_000,
   droppedSteps > 0 {
    fputs("Physics benchmark gate failed: dense-contact scenario dropped fixed steps.\n", stderr)
    exit(1)
}
