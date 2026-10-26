import Foundation
import CoveLogging
private var loggingConfiguration = LoggingConfiguration()
try loggingConfiguration.applyEnvironment(ProcessInfo.processInfo.environment)
try LogSystem.bootstrap(configuration: loggingConfiguration)
defer { LogSystem.flush() }
import SceneRuntime
import SIMDCompat

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

private struct Configuration {
    enum Scenario: String {
        case activeGrid = "active-grid"
        case denseContact = "dense-contact"
        case cloth64 = "cloth-64"
        case softBodyInstances = "soft-body-instances"
        case destructionFragments = "destruction-fragments"
        case destructionIslands = "destruction-islands"
    }

    var scenario: Scenario
    var backend: PhysicsBackendKind
    var bodyCount: Int
    var warmupFrames: Int
    var sampleFrames: Int
    var workerThreadCount: Int
    var maxResidentGrowthBytes: UInt64
    var clothGridSize: Int
    var maxSoftBodyStepNanoseconds: UInt64
    var maxVertexStreamNanoseconds: UInt64
    var maxDestructionActivationNanoseconds: UInt64
    var maxDestructionStepNanoseconds: UInt64
    var targetFPS: Double
    var maxFrameNanoseconds: UInt64
    var maxPhysicsNanoseconds: UInt64

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        func positive(_ key: String, fallback: Double) -> Double {
            guard let value = Double(environment[key] ?? ""), value.isFinite, value > 0 else { return fallback }
            return value
        }
        targetFPS = min(1_000, max(1, positive("COVE_PHYSICS_TARGET_FPS", fallback: 120)))
        let frameBudgetMS = 1_000 / targetFPS
        // Keep 88% of the frame available to the rest of the engine and game.
        let physicsBudgetMS = min(frameBudgetMS, positive("COVE_PHYSICS_BUDGET_MS", fallback: frameBudgetMS * 0.12))
        maxFrameNanoseconds = UInt64(frameBudgetMS * 1_000_000)
        maxPhysicsNanoseconds = UInt64(physicsBudgetMS * 1_000_000)
        scenario = Scenario(rawValue: environment["COVE_PHYSICS_SCENARIO"] ?? "") ?? .activeGrid
        backend = PhysicsBackendKind(rawValue: environment["COVE_PHYSICS_BACKEND"] ?? "") ?? .preferred
        let defaultBodyCount: Int
        switch scenario {
        case .activeGrid: defaultBodyCount = 10_000
        case .denseContact: defaultBodyCount = 2_000
        case .cloth64: defaultBodyCount = 1
        case .softBodyInstances: defaultBodyCount = 8
        case .destructionFragments, .destructionIslands: defaultBodyCount = 4_096
        }
        bodyCount = max(1, Int(environment["COVE_PHYSICS_BODIES"] ?? "") ?? defaultBodyCount)
        warmupFrames = max(0, Int(environment["COVE_PHYSICS_WARMUP_FRAMES"] ?? "") ?? 120)
        sampleFrames = max(1, Int(environment["COVE_PHYSICS_SAMPLE_FRAMES"] ?? "") ?? 600)
        workerThreadCount = Int(environment["COVE_PHYSICS_WORKERS"] ?? "") ?? 0
        maxResidentGrowthBytes = UInt64(environment["COVE_PHYSICS_MAX_RSS_GROWTH_BYTES"] ?? "")
            ?? 32 * 1_024 * 1_024
        clothGridSize = Int(environment["COVE_PHYSICS_CLOTH_GRID"] ?? "")
            ?? (scenario == .cloth64 ? 64 : 32)
        let stepBudgetMS = positive("COVE_PHYSICS_SOFT_STEP_BUDGET_MS", fallback: physicsBudgetMS)
        let streamBudgetMS = positive("COVE_PHYSICS_VERTEX_STREAM_BUDGET_MS", fallback: physicsBudgetMS * 0.1)
        maxSoftBodyStepNanoseconds = UInt64(max(0, stepBudgetMS) * 1_000_000)
        maxVertexStreamNanoseconds = UInt64(max(0, streamBudgetMS) * 1_000_000)
        let destructionBudgetMS = Double(
            environment["COVE_PHYSICS_DESTRUCTION_ACTIVATION_BUDGET_MS"] ?? ""
        ) ?? frameBudgetMS
        maxDestructionActivationNanoseconds = UInt64(max(0, destructionBudgetMS) * 1_000_000)
        let destructionStepBudgetMS = Double(
            environment["COVE_PHYSICS_DESTRUCTION_STEP_BUDGET_MS"] ?? ""
        ) ?? physicsBudgetMS
        maxDestructionStepNanoseconds = UInt64(max(0, destructionStepBudgetMS) * 1_000_000)
    }
}

private func makeBenchmarkScene(configuration: Configuration) -> SceneRuntime {
    var runtime = SceneRuntime()
    runtime.setPhysicsSettings(
        PhysicsSettingsResource(
            simulationMode: .play,
            backendKind: configuration.backend,
            gravity: configuration.scenario == .activeGrid ? .zero : SIMD3<Float>(0, -9.81, 0),
            fixedTimeStepSeconds: 1.0 / 60.0,
            maxSubstepsPerFrame: 1,
            allowSleep: false,
            collisionSteps: 1,
            capacity: PhysicsCapacitySettings(
                maxBodies: max(16_384, configuration.bodyCount + 16),
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
    case .destructionFragments, .destructionIslands:
        let fragmentsPerAsset = 16
        let usesIncrementalIslands = configuration.scenario == .destructionIslands
        let geometry = MeshColliderGeometry(
            positions: [
                SIMD3<Float>(-0.15, -0.15, -0.15),
                SIMD3<Float>(0.15, -0.15, -0.15),
                SIMD3<Float>(0, 0.15, -0.15),
                SIMD3<Float>(0, 0, 0.15),
            ],
            triangleIndices: [0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3]
        )
        var geometryByResourceID: [String: MeshColliderGeometry] = [:]
        var fragmentAssets: [DestructibleFragmentAsset] = []
        var connections: [DestructibleConnectionAsset] = []
        for fragmentID in 0..<fragmentsPerAsset {
            let geometryID = "benchmark.destructible.convex.\(fragmentID)"
            geometryByResourceID[geometryID] = geometry
            let x = Float(fragmentID % 4) * 0.32 - 0.48
            let y = Float((fragmentID / 4) % 2) * 0.32 - 0.16
            let z = Float(fragmentID / 8) * 0.32 - 0.16
            fragmentAssets.append(DestructibleFragmentAsset(
                fragmentID: UInt32(fragmentID),
                colliderResourceID: geometryID,
                localTransform: LocalTransform(translation: SIMD3<Float>(x, y, z)),
                mass: 0.25,
                renderMesh: usesIncrementalIslands
                    ? RenderMeshComponent(meshIndex: 0) : nil
            ))
            if fragmentID > 0 {
                connections.append(DestructibleConnectionAsset(
                    connectionID: UInt32(fragmentID - 1),
                    fragmentA: UInt32(fragmentID - 1),
                    fragmentB: UInt32(fragmentID),
                    impulseThreshold: usesIncrementalIslands && fragmentID == 1
                        ? 1 : 10_000
                ))
            }
        }
        runtime.setResource(MeshColliderGeometryResource(
            geometryByResourceID: geometryByResourceID
        ))
        runtime.setResource(DestructibleAssetResource(assetsByResourceID: [
            "benchmark.destructible": DestructibleAsset(
                fragments: fragmentAssets,
                connections: connections
            ),
        ]))
        runtime.setResource(DestructionSettingsResource(
            maximumActiveFragmentCount: configuration.bodyCount,
            maximumEventCountPerFrame: max(1_024, configuration.bodyCount)
        ))
        let activatedFragmentsPerSource = usesIncrementalIslands
            ? fragmentsPerAsset - 1 : fragmentsPerAsset
        let sourceCount = Int(ceil(
            Double(configuration.bodyCount) / Double(activatedFragmentsPerSource)
        ))
        let columns = max(1, Int(ceil(sqrt(Double(sourceCount)))))
        for sourceIndex in 0..<sourceCount {
            let entity = runtime.createEntity()
            _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(
                Float(sourceIndex % columns) * 2,
                5 + Float(sourceIndex % 3) * 2,
                Float(sourceIndex / columns) * 2
            )), for: entity)
            _ = runtime.setComponent(
                Collider(shape: .box(
                    halfExtents: SIMD3<Float>(0.7, 0.4, 0.4),
                    center: .zero
                )),
                for: entity
            )
            _ = runtime.setComponent(RigidBody(motionType: .static), for: entity)
            let remaining = configuration.bodyCount
                - sourceIndex * activatedFragmentsPerSource
            _ = runtime.setComponent(Destructible(
                assetResourceID: "benchmark.destructible",
                damageThreshold: usesIncrementalIslands ? 10_000 : 1,
                impulseThreshold: usesIncrementalIslands ? 10_000 : 1,
                fragmentBudget: min(activatedFragmentsPerSource, remaining),
                maximumFragmentLifetimeSeconds: 0,
                sleepingRecycleDelaySeconds: 0,
                separationImpulse: 0.25
            ), for: entity)
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
    #if os(Windows)
    guard let counters = processMemoryCounters() else { return 0 }
    return UInt64(counters.PeakWorkingSetSize)
    #else
    var usage = rusage()
    #if os(macOS)
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(usage.ru_maxrss)
    #else
    guard getrusage(RUSAGE_SELF.rawValue, &usage) == 0 else { return 0 }
    return UInt64(usage.ru_maxrss) * 1024
    #endif
    #endif
}

#if os(Windows)
private func processMemoryCounters() -> PROCESS_MEMORY_COUNTERS? {
    var counters = PROCESS_MEMORY_COUNTERS()
    let size = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS>.size)
    counters.cb = size
    guard K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, size) else { return nil }
    return counters
}
#endif

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
    #elseif os(Windows)
    guard let counters = processMemoryCounters() else { return 0 }
    return UInt64(counters.WorkingSetSize)
    #else
    return 0
    #endif
}

private let configuration = Configuration()
var runtime = makeBenchmarkScene(configuration: configuration)
for frame in 0..<configuration.warmupFrames {
    _ = runtime.tick(deltaTime: 1.0 / 60.0, frameIndex: UInt64(frame))
}
if configuration.scenario == .destructionFragments
    || configuration.scenario == .destructionIslands {
    for entity in runtime.entities(with: Destructible.self).sorted(by: {
        $0.rawValue < $1.rawValue
    }) {
        if configuration.scenario == .destructionIslands {
            runtime.submitDestructionCommand(DestructionCommand(
                entity: entity,
                impulse: SIMD3<Float>(2, 0, 0)
            ))
        } else {
            runtime.submitDestructionCommand(DestructionCommand(
                entity: entity,
                forceFracture: true
            ))
        }
    }
}

var stepSamples: [UInt64] = []
var frameSamples: [UInt64] = []
var physicsSamples: [UInt64] = []
var phaseSamples: [RuntimeSystemPhase: [UInt64]] = [:]
let physicsPhases: [RuntimeSystemPhase] = [.fixedPhysicsPrepare, .fixedPhysicsStep, .physicsWriteback, .spatialIndexUpdate, .triggerDetection]
var backendErrorCount = 0
var syncSamples: [UInt64] = []
var contactTotal = 0
var activeBodyPeak = 0
var activeSoftBodyPeak = 0
var droppedSteps = 0
var residentSamples: [UInt64] = []
var vertexStreamSamples: [UInt64] = []
var streamedVertexPeak = 0
var vertexChecksum: Float = 0
var activeFragmentPeak = 0
var destructionEventTotal = 0
var destructionActivationNanoseconds: UInt64 = 0
var partiallyFracturedSourcePeak = 0
var fullyFracturedSourcePeak = 0
var retainedFragmentPeak = 0
var retainedProxyPeak = 0
var compoundRootPeak = 0
stepSamples.reserveCapacity(configuration.sampleFrames)
frameSamples.reserveCapacity(configuration.sampleFrames)
physicsSamples.reserveCapacity(configuration.sampleFrames)
syncSamples.reserveCapacity(configuration.sampleFrames)
residentSamples.reserveCapacity(configuration.sampleFrames)
vertexStreamSamples.reserveCapacity(configuration.sampleFrames)

for offset in 0..<configuration.sampleFrames {
    let frame = configuration.warmupFrames + offset
    let frameStarted = DispatchTime.now().uptimeNanoseconds
    let report = runtime.tick(deltaTime: 1.0 / 60.0, frameIndex: UInt64(frame))
    frameSamples.append(DispatchTime.now().uptimeNanoseconds - frameStarted)
    physicsSamples.append(physicsPhases.reduce(0) { $0 + (report.phaseNanoseconds[$1] ?? 0) })
    for phase in RuntimeSystemPhase.allCases { phaseSamples[phase, default: []].append(report.phaseNanoseconds[phase] ?? 0) }
    if report.physics.error != nil { backendErrorCount += 1 }
    if (configuration.scenario == .destructionFragments
        || configuration.scenario == .destructionIslands) && offset == 0 {
        destructionActivationNanoseconds = DispatchTime.now().uptimeNanoseconds - frameStarted
    }
    stepSamples.append(report.physics.stepNanoseconds)
    syncSamples.append(report.physics.synchronizationNanoseconds)
    contactTotal += report.physics.contactCount
    activeBodyPeak = max(activeBodyPeak, runtime.physicsFrameState.activeBodyCount)
    activeSoftBodyPeak = max(
        activeSoftBodyPeak, runtime.physicsFrameState.activeSoftBodyCount
    )
    droppedSteps += report.physics.droppedStepCount
    activeFragmentPeak = max(activeFragmentPeak, runtime.destructionStateFrame.activeFragmentCount)
    destructionEventTotal += runtime.destructionEventFrame.events.count
    let destructionStates = runtime.destructionStateFrame.sources.values
    partiallyFracturedSourcePeak = max(
        partiallyFracturedSourcePeak,
        destructionStates.filter { $0.hasFractured && !$0.isFullyFractured }.count
    )
    fullyFracturedSourcePeak = max(
        fullyFracturedSourcePeak,
        destructionStates.filter(\.isFullyFractured).count
    )
    retainedFragmentPeak = max(
        retainedFragmentPeak,
        destructionStates.reduce(0) { $0 + $1.retainedFragmentIDs.count }
    )
    retainedProxyPeak = max(
        retainedProxyPeak,
        runtime.entities(with: DestructibleRetainedFragment.self).count
    )
    let compoundRoots = destructionStates.filter { state in
        guard state.hasFractured, !state.isFullyFractured,
              let collider = runtime.component(Collider.self, for: state.sourceEntity)
        else { return false }
        return collider.shapes.count == state.retainedFragmentIDs.count
            && zip(collider.shapes, state.retainedFragmentIDs).allSatisfy {
                $0.0.shape.resourceID == "benchmark.destructible.convex.\($0.1)"
            }
    }.count
    compoundRootPeak = max(compoundRootPeak, compoundRoots)
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
let sortedFrames = frameSamples.sorted()
let sortedPhysics = physicsSamples.sorted()
let sortedSync = syncSamples.sorted()
let sortedVertexStream = vertexStreamSamples.sorted()
let windowSize = max(1, configuration.sampleFrames / 10)
let initialResident = percentile(Array(residentSamples.prefix(windowSize)).sorted(), 0.50)
let finalResident = percentile(Array(residentSamples.suffix(windowSize)).sorted(), 0.50)
let residentGrowth = finalResident > initialResident ? finalResident - initialResident : 0
print("PhysicsRuntimeBenchmarks backend=\(runtime.physicsFrameState.backendIdentifier) requested_backend=\(configuration.backend.rawValue) scenario=\(configuration.scenario.rawValue) bodies=\(configuration.bodyCount) workers=\(configuration.workerThreadCount) warmup=\(configuration.warmupFrames) frames=\(configuration.sampleFrames)")
print("target_fps=\(configuration.targetFPS) cpu_tick_budget_ms=\(milliseconds(configuration.maxFrameNanoseconds)) physics_cpu_budget_ms=\(milliseconds(configuration.maxPhysicsNanoseconds)) full_rendered_frame_verified=false")
print("cpu_tick_ms p50=\(milliseconds(percentile(sortedFrames, 0.50))) p95=\(milliseconds(percentile(sortedFrames, 0.95))) p99=\(milliseconds(percentile(sortedFrames, 0.99))) max=\(milliseconds(sortedFrames.last ?? 0))")
print("physics_cpu_ms p50=\(milliseconds(percentile(sortedPhysics, 0.50))) p95=\(milliseconds(percentile(sortedPhysics, 0.95))) p99=\(milliseconds(percentile(sortedPhysics, 0.99)))")
for phase in RuntimeSystemPhase.allCases {
    let samples = (phaseSamples[phase] ?? []).sorted()
    print("phase_ms phase=\(phase.rawValue) p50=\(milliseconds(percentile(samples, 0.50))) p95=\(milliseconds(percentile(samples, 0.95))) p99=\(milliseconds(percentile(samples, 0.99)))")
}
print("step_ms p50=\(milliseconds(percentile(sortedSteps, 0.50))) p95=\(milliseconds(percentile(sortedSteps, 0.95))) p99=\(milliseconds(percentile(sortedSteps, 0.99)))")
print("sync_ms p50=\(milliseconds(percentile(sortedSync, 0.50))) p95=\(milliseconds(percentile(sortedSync, 0.95))) p99=\(milliseconds(percentile(sortedSync, 0.99)))")
print("vertex_stream_ms p50=\(milliseconds(percentile(sortedVertexStream, 0.50))) p95=\(milliseconds(percentile(sortedVertexStream, 0.95))) p99=\(milliseconds(percentile(sortedVertexStream, 0.99))) vertices_peak=\(streamedVertexPeak) checksum=\(vertexChecksum)")
print("contacts_total=\(contactTotal) active_body_peak=\(activeBodyPeak) active_soft_body_peak=\(activeSoftBodyPeak) dropped_steps=\(droppedSteps) peak_rss_bytes=\(peakResidentBytes())")
print("rss_initial_bytes=\(initialResident) rss_final_bytes=\(finalResident) rss_growth_bytes=\(residentGrowth)")
print("destruction_activation_ms=\(milliseconds(destructionActivationNanoseconds)) active_fragment_peak=\(activeFragmentPeak) destruction_events_total=\(destructionEventTotal)")
print("destruction_partial_source_peak=\(partiallyFracturedSourcePeak) destruction_full_source_peak=\(fullyFracturedSourcePeak) retained_fragment_peak=\(retainedFragmentPeak) retained_proxy_peak=\(retainedProxyPeak) compound_root_peak=\(compoundRootPeak)")

var failures: [String] = []
@MainActor
func checkBudget(_ name: String, _ samples: [UInt64], _ budget: UInt64) {
    let p95 = percentile(samples, 0.95), p99 = percentile(samples, 0.99)
    if p95 > budget || p99 > budget {
        failures.append("\(name) exceeds \(milliseconds(budget)) ms: P95=\(milliseconds(p95)), P99=\(milliseconds(p99))")
    }
}
checkBudget("CPU tick", sortedFrames, configuration.maxFrameNanoseconds)
checkBudget("Physics CPU envelope", sortedPhysics, configuration.maxPhysicsNanoseconds)
if frameSamples.count < 100 { failures.append("At least 100 measured frames are required for P99 acceptance") }
if backendErrorCount > 0 { failures.append("Backend reported errors in \(backendErrorCount) frames") }
if droppedSteps > 0 { failures.append("Dropped \(droppedSteps) fixed steps") }
if activeSoftBodyPeak > 0 {
    checkBudget("Soft-body step", sortedSteps, configuration.maxSoftBodyStepNanoseconds)
    checkBudget("Vertex stream", sortedVertexStream, configuration.maxVertexStreamNanoseconds)
}
if configuration.scenario == .destructionFragments,
   activeFragmentPeak != configuration.bodyCount
        || destructionActivationNanoseconds > configuration.maxDestructionActivationNanoseconds
        || percentile(sortedSteps, 0.95) > configuration.maxDestructionStepNanoseconds {
    failures.append("Destructible activation missed its fragment count or burst/step budget")
}
if configuration.scenario == .destructionIslands {
    let expectedSourceCount = Int(ceil(Double(configuration.bodyCount) / 15.0))
    if activeFragmentPeak != configuration.bodyCount
        || partiallyFracturedSourcePeak != expectedSourceCount
        || fullyFracturedSourcePeak != 0
        || retainedFragmentPeak != expectedSourceCount
        || retainedProxyPeak != expectedSourceCount
        || compoundRootPeak != expectedSourceCount
        || destructionActivationNanoseconds > configuration.maxDestructionActivationNanoseconds
        || percentile(sortedSteps, 0.95) > configuration.maxDestructionStepNanoseconds {
        failures.append("Incremental destruction missed its fragment/source/compound/proxy count or burst/step budget")
    }
}
if initialResident > 0,
   finalResident > 0,
   residentGrowth > configuration.maxResidentGrowthBytes {
    failures.append("Sustained resident-memory growth exceeded the configured budget")
}
print("gate_status=\(failures.isEmpty ? "passed" : "failed") failed_checks=\(failures.count)")
for failure in failures { LogSystem.logger("com.cove.tools").error("Physics benchmark gate failed: \(failure)") }
LogSystem.flush()
if !failures.isEmpty { exit(1) }
