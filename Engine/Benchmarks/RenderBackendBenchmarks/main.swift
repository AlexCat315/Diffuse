import Foundation
import RenderBackend
import RHIWGPU
import SceneRuntime
import simd

struct BenchmarkConfig {
    var instanceCounts: [Int] = [5_000, 20_000, 80_000]
    var chunkSizes: [Int] = [0, 64, 128, 256, 512]
    var groupedDrawOptions: [Bool] = [false, true]
    var frameCount: Int = 100
    var warmupFrameCount: Int = 20
    var drawableSize = RenderDrawableSize(width: 1600, height: 900)
}

private func resolveConfig(from args: [String]) -> BenchmarkConfig {
    var config = BenchmarkConfig()
    if args.contains("--quick") {
        config.instanceCounts = [5_000]
        config.chunkSizes = [0, 128]
        config.groupedDrawOptions = [false, true]
        config.frameCount = 24
        config.warmupFrameCount = 6
    }
    return config
}

private func makeScene(instanceCount: Int) -> RenderScene {
    let camera = RenderCamera(
        eye: SIMD3<Float>(0, 10, 24),
        target: SIMD3<Float>(0, 4, 0),
        up: SIMD3<Float>(0, 1, 0),
        fovYRadians: .pi / 3,
        near: 0.1,
        far: 200.0
    )

    var instances: [RenderInstance] = []
    instances.reserveCapacity(instanceCount)

    for i in 0..<instanceCount {
        let gx = Float(i % 100) - 50
        let gz = Float((i / 100) % 100) - 50
        let y = Float((i / 10_000) % 5) * 1.2
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(gx * 0.9, y, gz * 0.9, 1)
        instances.append(RenderInstance(meshIndex: i % 2, transform: transform))
    }

    return RenderScene(camera: camera, instances: instances)
}

private func percentile(_ sorted: [UInt64], _ p: Double) -> UInt64 {
    guard !sorted.isEmpty else { return 0 }
    let idx = min(max(Int(Double(sorted.count - 1) * p), 0), sorted.count - 1)
    return sorted[idx]
}

private func average(_ values: [UInt64]) -> UInt64 {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / UInt64(values.count)
}

private func averageInt(_ values: [Int]) -> Double {
    guard !values.isEmpty else { return 0 }
    return Double(values.reduce(0, +)) / Double(values.count)
}

private func formatNS(_ ns: UInt64) -> String {
    String(format: "%.3fms", Double(ns) / 1_000_000.0)
}

private func runCase(
    config: BenchmarkConfig,
    instanceCount: Int,
    enableBundles: Bool,
    groupedDraw: Bool,
    chunkSize: Int
) throws -> [RenderFrameStats] {
    let backend = WGPUBackend(config: WGPUDeviceConfig(validationEnabled: false))
    try backend.initialize()
    defer { try? backend.shutdown() }

    let renderer = WGPURenderer(backend: backend, renderSurface: nil)
    renderer.initialize()

    let scene = makeScene(instanceCount: instanceCount)
    let settings = RenderSettings(
        stage: .r1MeshCamera,
        enableFXAA: false,
        enableSSAO: false,
        enableSSR: false,
        enableTAA: false,
        enableBloom: false,
        enableRenderBundles: enableBundles,
        enableGroupedDrawByMesh: groupedDraw,
        renderBundleChunkSize: chunkSize,
        enableShadows: false,
        enableOffscreenViewport: true
    )

    var samples: [RenderFrameStats] = []
    samples.reserveCapacity(max(0, config.frameCount - config.warmupFrameCount))

    for frameIndex in 0..<config.frameCount {
        let packet = RenderPacket(
            frameIndex: frameIndex,
            deltaTime: 1.0 / 60.0,
            drawableSize: config.drawableSize,
            scene: scene,
            sceneSnapshot: SceneRuntimeSnapshot(entityCount: instanceCount, revision: UInt64(frameIndex)),
            renderSettings: settings,
            simulationTimeSeconds: Double(frameIndex) / 60.0
        )

        renderer.render(packet: packet)
        let stats = renderer.currentFrameStats()
        if frameIndex >= config.warmupFrameCount {
            samples.append(stats)
        }
    }

    return samples
}

private func summarize(label: String, samples: [RenderFrameStats]) {
    let total = samples.map(\ .cpuFrameTotalNS).sorted()
    let encode = samples.map(\ .cpuEncodeNS).sorted()
    let base = samples.map(\ .cpuBaseEncodeNS).sorted()
    let post = samples.map(\ .cpuPostProcessEncodeNS).sorted()

    let avgBundles = averageInt(samples.map(\ .renderBundleCount))
    let avgBundleJobs = averageInt(samples.map(\ .renderBundleParallelJobs))

    print("[\(label)] samples=\(samples.count) " +
          "frame_avg=\(formatNS(average(total))) frame_p95=\(formatNS(percentile(total, 0.95))) " +
          "encode_avg=\(formatNS(average(encode))) encode_p95=\(formatNS(percentile(encode, 0.95))) " +
          "base_avg=\(formatNS(average(base))) post_avg=\(formatNS(average(post))) " +
          "avg_bundles=\(String(format: "%.2f", avgBundles)) " +
          "avg_bundle_jobs=\(String(format: "%.2f", avgBundleJobs))")
}

private struct CaseSummary {
    var encodeAvgNS: UInt64
    var encodeP95NS: UInt64
    var baseAvgNS: UInt64
    var frameAvgNS: UInt64

    init(samples: [RenderFrameStats]) {
        let encode = samples.map(\ .cpuEncodeNS).sorted()
        let base = samples.map(\ .cpuBaseEncodeNS).sorted()
        let frame = samples.map(\ .cpuFrameTotalNS).sorted()
        self.encodeAvgNS = average(encode)
        self.encodeP95NS = percentile(encode, 0.95)
        self.baseAvgNS = average(base)
        self.frameAvgNS = average(frame)
    }
}

private struct PivotSummary {
    var instanceCount: Int
    var groupedDraw: Bool
    var chunkSize: Int
    var bestDeltaEncodeNS: Int64

    var breakEvenReached: Bool {
        bestDeltaEncodeNS > 0
    }
}

private func printOverviewTable(_ pivots: [PivotSummary]) {
    guard !pivots.isEmpty else { return }
    print("\n=== bundle_pivot_overview ===")
    print("instances | best_chunk | grouped | break_even | best_encode_delta_ms")
    print("--------- | ---------- | ------- | ---------- | --------------------")
    for pivot in pivots.sorted(by: { $0.instanceCount < $1.instanceCount }) {
        let deltaMS = Double(abs(pivot.bestDeltaEncodeNS)) / 1_000_000.0
        let groupedText = pivot.groupedDraw ? "true" : "false"
        let breakEvenText = pivot.breakEvenReached ? "true" : "false"
        print("\(pivot.instanceCount) | \(pivot.chunkSize) | \(groupedText) | \(breakEvenText) | \(String(format: "%.3f", deltaMS))")
    }
}

let config = resolveConfig(from: CommandLine.arguments.dropFirst().map { $0 })
print("RenderBackendBenchmarks instances=\(config.instanceCounts) chunks=\(config.chunkSizes) grouped=\(config.groupedDrawOptions) frames=\(config.frameCount) warmup=\(config.warmupFrameCount) size=\(config.drawableSize.width)x\(config.drawableSize.height)")

do {
    var bestPivotByInstance: [Int: PivotSummary] = [:]

    for groupedDraw in config.groupedDrawOptions {
        print("\n=== groupedDraw=\(groupedDraw) ===")
        for instanceCount in config.instanceCounts {
            print("-- instances=\(instanceCount) --")

            var bestChunk = -1
            var bestDeltaEncodeNS = Int64.min

            for chunkSize in config.chunkSizes {
                let onSamples = try runCase(
                    config: config,
                    instanceCount: instanceCount,
                    enableBundles: true,
                    groupedDraw: groupedDraw,
                    chunkSize: chunkSize
                )
                let offSamples = try runCase(
                    config: config,
                    instanceCount: instanceCount,
                    enableBundles: false,
                    groupedDraw: groupedDraw,
                    chunkSize: chunkSize
                )

                let onSummary = CaseSummary(samples: onSamples)
                let offSummary = CaseSummary(samples: offSamples)

                summarize(label: "bundle=on grouped=\(groupedDraw) instances=\(instanceCount) chunk=\(chunkSize)", samples: onSamples)
                summarize(label: "bundle=off grouped=\(groupedDraw) instances=\(instanceCount) chunk=\(chunkSize)", samples: offSamples)

                let encodeDeltaNS = Int64(offSummary.encodeAvgNS) - Int64(onSummary.encodeAvgNS)
                let gainPct = offSummary.encodeAvgNS == 0
                    ? 0
                    : (Double(encodeDeltaNS) / Double(offSummary.encodeAvgNS)) * 100.0

                print("[compare] instances=\(instanceCount) grouped=\(groupedDraw) chunk=\(chunkSize) encode_delta=\(formatNS(UInt64(abs(encodeDeltaNS)))) direction=\(encodeDeltaNS >= 0 ? "bundle_faster" : "bundle_slower") gain_pct=\(String(format: "%.2f", gainPct))")

                if encodeDeltaNS > bestDeltaEncodeNS {
                    bestDeltaEncodeNS = encodeDeltaNS
                    bestChunk = chunkSize
                }
            }

            let breakEvenReached = bestDeltaEncodeNS > 0
            print("[pivot] instances=\(instanceCount) grouped=\(groupedDraw) best_chunk=\(bestChunk) break_even=\(breakEvenReached) best_encode_delta=\(formatNS(UInt64(abs(bestDeltaEncodeNS))))")

            let pivot = PivotSummary(
                instanceCount: instanceCount,
                groupedDraw: groupedDraw,
                chunkSize: bestChunk,
                bestDeltaEncodeNS: bestDeltaEncodeNS
            )
            if let existing = bestPivotByInstance[instanceCount] {
                if pivot.bestDeltaEncodeNS > existing.bestDeltaEncodeNS {
                    bestPivotByInstance[instanceCount] = pivot
                }
            } else {
                bestPivotByInstance[instanceCount] = pivot
            }
        }
    }

    printOverviewTable(Array(bestPivotByInstance.values))
} catch {
    print("benchmark failed: \(error)")
    exit(1)
}
