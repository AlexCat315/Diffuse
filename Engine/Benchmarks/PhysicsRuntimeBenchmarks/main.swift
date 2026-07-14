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
        case cloth64 = "cloth-64"
        case softBodyInstances = "soft-body-instances"
    }

    var scenario: Scenario
    var bodyCount: Int
    var warmupFrames: Int
    var sampleFrames: Int
    var workerThreadCount: Int
    var maxResidentGrowthBytes: UInt64
    var clothGridSize: Int
    var maxSoftBodyStepNanoseconds: UInt64
    var maxVertexStreamNanoseconds: UInt64

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        scenario = Scenario(rawValue: environment["GUAVA_PHYSICS_SCENARIO"] ?? "") ?? .activeGrid
        let defaultBodyCount: Int
        switch scenario {
        case .activeGrid: defaultBodyCount = 10_000
        case .denseContact: defaultBodyCount = 2_000
        case .cloth64: defaultBodyCount = 1
        case .softBodyInstances: defaultBodyCount = 8
        }
        bodyCount = Int(environment["GUAVA_PHYSICS_BODIES"] ?? "") ?? defaultBodyCount
        warmupFrames = Int(environment["GUAVA_PHYSICS_WARMUP_FRAMES"] ?? "") ?? 120
        sampleFrames = Int(environment["GUAVA_PHYSICS_SAMPLE_FRAMES"] ?? "") ?? 600
        workerThreadCount = Int(environment["GUAVA_PHYSICS_WORKERS"] ?? "") ?? 0
        maxResidentGrowthBytes = UInt64(environment["GUAVA_PHYSICS_MAX_RSS_GROWTH_BYTES"] ?? "")
            ?? 32 * 1_024 * 1_024
        clothGridSize = Int(environment["GUAVA_PHYSICS_CLOTH_GRID"] ?? "")
            ?? (scenario == .cloth64 ? 64 : 32)
        let stepBudgetMS = Double(environment["GUAVA_PHYSICS_SOFT_STEP_BUDGET_MS"] ?? "")
            ?? 16.67
        let streamBudgetMS = Double(environment["GUAVA_PHYSICS_VERTEX_STREAM_BUDGET_MS"] ?? "")
            ?? 2.0
        maxSoftBodyStepNanoseconds = UInt64(max(0, stepBudgetMS) * 1_000_000)
        maxVertexStreamNanoseconds = UInt64(max(0, streamBudgetMS) * 1_000_000)
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

    switch configuration.scenario {
    case .activeGrid, .denseContact:
        let activeColumns = max(1, Int(ceil(sqrt(Double(configuration.bodyCount)))))
        let denseColumns = 20
        for index in 0..<configuration.bodyCount {
            let position: SIMD3<Float>
            if configuration.scenario == .activeGrid {
                position = SIMD3<Float>(
                    Float(index % activeColumns) * 1.1 - Float(activeColumns) * 0.55,
                    1 + Float(index % 5) * 1.1,
                    Float(index / activeColumns) * 1.1 - Float(activeColumns) * 0.55
                )
            } else {
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
    case .cloth64, .softBodyInstances:
        let gridSize = max(2, min(configuration.clothGridSize, 512))
        let instanceCount = configuration.scenario == .cloth64
            ? 1 : max(1, configuration.bodyCount)
        let columns = max(1, Int(ceil(sqrt(Double(instanceCount)))))
        for index in 0..<instanceCount {
            let entity = runtime.createEntity()
            let position = SIMD3<Float>(
                Float(index % columns) * Float(gridSize) * 0.06,
                8 + Float(index % 3),
                Float(index / columns) * Float(gridSize) * 0.06
            )
            _ = runtime.setLocalTransform(LocalTransform(translation: position), for: entity)
            _ = runtime.setComponent(
                Cloth.fixedTopEdge(
                    gridSizeX: gridSize,
                    gridSizeZ: gridSize,
                    spacing: 0.05
                ),
                for: entity
            )
            _ = runtime.setComponent(
                SoftBody(
                    vertexMass: 0.05,
                    linearDamping: 0.05,
                    solverIterations: 5,
                    allowSleep: false,
                    selfCollision: configuration.scenario == .cloth64
                ),
                for: entity
            )
            _ = runtime.setComponent(RenderMeshComponent(meshIndex: 0), for: entity)
        }
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

private func residentBytes() -> UInt64 {
    #if os(macOS)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return UInt64(info.resident_size)
    #elseif os(Linux)
    guard let contents = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8),
          let residentPages = contents.split(separator: " ").dropFirst().first.flatMap({ UInt64($0) })
    else { return 0 }
    return residentPages * UInt64(sysconf(Int32(_SC_PAGESIZE)))
    #else
    return 0
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
var activeSoftBodyPeak = 0
var droppedSteps = 0
var residentSamples: [UInt64] = []
var vertexStreamSamples: [UInt64] = []
var streamedVertexPeak = 0
var vertexChecksum: Float = 0
stepSamples.reserveCapacity(configuration.sampleFrames)
syncSamples.reserveCapacity(configuration.sampleFrames)
residentSamples.reserveCapacity(configuration.sampleFrames)
vertexStreamSamples.reserveCapacity(configuration.sampleFrames)

for offset in 0..<configuration.sampleFrames {
    let frame = configuration.warmupFrames + offset
    let report = runtime.tick(deltaTime: 1.0 / 60.0, frameIndex: UInt64(frame))
    stepSamples.append(report.physicsStepNanoseconds)
    syncSamples.append(report.physicsSynchronizationNanoseconds)
    contactTotal += report.physicsContactCount
    activeBodyPeak = max(activeBodyPeak, runtime.physicsFrameState.activeBodyCount)
    activeSoftBodyPeak = max(
        activeSoftBodyPeak, runtime.physicsFrameState.activeSoftBodyCount
    )
    droppedSteps += report.physicsDroppedStepCount
    residentSamples.append(residentBytes())
    let streamStarted = DispatchTime.now().uptimeNanoseconds
    let deformableMeshes = runtime.renderScene.deformableMeshes
    streamedVertexPeak = max(
        streamedVertexPeak,
        deformableMeshes.reduce(0) { $0 + $1.vertexCount }
    )
    for mesh in deformableMeshes {
        for position in mesh.positions {
            vertexChecksum += position.x * 0.000_001
                + position.y * 0.000_002
                + position.z * 0.000_003
        }
    }
    vertexStreamSamples.append(DispatchTime.now().uptimeNanoseconds - streamStarted)
}

let sortedSteps = stepSamples.sorted()
let sortedSync = syncSamples.sorted()
let sortedVertexStream = vertexStreamSamples.sorted()
let windowSize = max(1, configuration.sampleFrames / 10)
let initialResident = percentile(Array(residentSamples.prefix(windowSize)).sorted(), 0.50)
let finalResident = percentile(Array(residentSamples.suffix(windowSize)).sorted(), 0.50)
let residentGrowth = finalResident > initialResident ? finalResident - initialResident : 0
print("PhysicsRuntimeBenchmarks scenario=\(configuration.scenario.rawValue) bodies=\(configuration.bodyCount) frames=\(configuration.sampleFrames)")
print("step_ms p50=\(milliseconds(percentile(sortedSteps, 0.50))) p95=\(milliseconds(percentile(sortedSteps, 0.95))) p99=\(milliseconds(percentile(sortedSteps, 0.99)))")
print("sync_ms p50=\(milliseconds(percentile(sortedSync, 0.50))) p95=\(milliseconds(percentile(sortedSync, 0.95))) p99=\(milliseconds(percentile(sortedSync, 0.99)))")
print("vertex_stream_ms p50=\(milliseconds(percentile(sortedVertexStream, 0.50))) p95=\(milliseconds(percentile(sortedVertexStream, 0.95))) p99=\(milliseconds(percentile(sortedVertexStream, 0.99))) vertices_peak=\(streamedVertexPeak) checksum=\(vertexChecksum)")
print("contacts_total=\(contactTotal) active_body_peak=\(activeBodyPeak) active_soft_body_peak=\(activeSoftBodyPeak) dropped_steps=\(droppedSteps) peak_rss_bytes=\(peakResidentBytes())")
print("rss_initial_bytes=\(initialResident) rss_final_bytes=\(finalResident) rss_growth_bytes=\(residentGrowth)")

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
if configuration.scenario == .cloth64,
   configuration.clothGridSize >= 64,
   percentile(sortedSteps, 0.95) > configuration.maxSoftBodyStepNanoseconds
        || percentile(sortedVertexStream, 0.95) > configuration.maxVertexStreamNanoseconds
        || droppedSteps > 0 {
    fputs("Physics benchmark gate failed: 64x64 cloth exceeded the step/vertex-stream budget or dropped fixed steps.\n", stderr)
    exit(1)
}
if configuration.scenario == .softBodyInstances,
   configuration.bodyCount >= 8,
   configuration.clothGridSize >= 32,
   percentile(sortedSteps, 0.95) > configuration.maxSoftBodyStepNanoseconds
        || percentile(sortedVertexStream, 0.95) > configuration.maxVertexStreamNanoseconds
        || droppedSteps > 0 {
    fputs("Physics benchmark gate failed: medium soft-body instances exceeded the step/vertex-stream budget or dropped fixed steps.\n", stderr)
    exit(1)
}
if initialResident > 0,
   finalResident > 0,
   residentGrowth > configuration.maxResidentGrowthBytes {
    fputs("Physics benchmark gate failed: sustained resident-memory growth exceeded the configured budget.\n", stderr)
    exit(1)
}
