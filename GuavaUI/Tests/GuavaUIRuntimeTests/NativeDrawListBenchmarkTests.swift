#if os(macOS)
import Foundation
import NativeRHI
import RHIWGPU
import Testing
@testable import GuavaUIRuntime

private struct NativeUITiming: Codable {
    let p50Microseconds: Double
    let p95Microseconds: Double
    let sampleCount: Int
    init(_ samples: [Double]) {
        let sorted = samples.sorted(); sampleCount = samples.count
        p50Microseconds = sorted[Int(ceil(Double(sorted.count) * 0.5)) - 1]
        p95Microseconds = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
    }
}

private struct NativeUIBenchmarkResult: Codable {
    let backend: String
    let cpuFrame: NativeUITiming
    let cpuRecord: NativeUITiming
    let cpuSubmit: NativeUITiming
    let completedBatch: NativeUITiming
}

private struct NativeUIFrameTiming {
    let recordNanoseconds: UInt64
    let submitNanoseconds: UInt64
}

private struct NativeUIBenchmarkWork: Codable {
    let vertices: Int
    let indices: Int
    let draws: Int
}

private struct NativeUIBenchmarkReport: Codable {
    let device: String
    let width: Int
    let height: Int
    let samples = 4
    let format = "bgra8UnormSRGB"
    let frames = 180
    let warmup = 30
    let repeats = 3
    let work: NativeUIBenchmarkWork
    let results: [NativeUIBenchmarkResult]
}

@Suite("Native draw list release benchmark", .serialized)
struct NativeDrawListBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GUAVA_NATIVE_UI_BENCHMARK"] == "1"))
    func equivalentWork() throws {
        #if DEBUG
        throw RHIError.invalidArgument("run the UI benchmark with swift test -c release")
        #else
        let context = try NativeUIDrawTestContext(validation: false)
        let scene = try nativeUIScene(context)
        let list = tiled(scene)
        let format = NativeUITestFormat.cases[3]
        for size in [SIMD2(1280, 720), SIMD2(1920, 1080)] {
            let viewport = NativeUIViewport(pixels: size, logical: SIMD2(1280, 720))
            let (actual, statistics) = try context.nativeImage(list: list, format: format, samples: 4, viewport: viewport)
            let expected = try context.referenceImage(list: list, format: format, samples: 4, viewport: viewport)
            try expectNativeUIParity(actual, expected, format: format, label: "benchmark/\(size)")
            #expect(statistics.drawCalls == list.batches.filter { $0.indexCount > 0 && $0.scissor?.width != 0 }.count)
            try context.native.configure(format: format.native, sampleCount: 4)
            try context.reference.configure(format: format.reference, sampleCount: 4)
            let output = try context.nativeOutput(format: format.native, size: size)
            let multisample = try TextureResource(device: context.device, descriptor: TextureDescriptor(width: size.x, height: size.y,
                format: format.native, usage: .colorTarget, sampleCount: 4))
            var target = RenderColorTarget(texture: multisample.texture, loadAction: .clear(SIMD4(0.07, 0.09, 0.12, 0.5)), store: false)
            target.resolveTexture = output.texture
            let referenceOutput = try context.backend.createTexture(width: UInt32(size.x), height: UInt32(size.y),
                format: format.reference, usage: .renderAttachment)
            let referenceMS = try context.backend.createTexture(width: UInt32(size.x), height: UInt32(size.y),
                format: format.reference, usage: .renderAttachment, sampleCount: 4)
            let referenceOutputView = try referenceOutput.createView(), referenceMSView = try referenceMS.createView()
            var lastStatistics = statistics
            let native = try measure("native-metal", render: {
                try context.device.beginFrame()
                do {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let commands = CommandBuffer()
                    let frame = try context.native.record(list: list, into: commands, target: target, viewport: viewport)
                    lastStatistics = frame.statistics
                    let recorded = DispatchTime.now().uptimeNanoseconds
                    try context.device.submit(commands); frame.didSubmit()
                    context.device.endFrame()
                    return NativeUIFrameTiming(recordNanoseconds: recorded - start,
                        submitNanoseconds: DispatchTime.now().uptimeNanoseconds - recorded)
                } catch { context.device.endFrame(); throw error }
            }, finish: { try context.device.waitUntilIdle() })
            #expect(lastStatistics.drawCalls == statistics.drawCalls && lastStatistics.textureUploads == 0)
            let reference = try measure("wgpu-metal", render: {
                let start = DispatchTime.now().uptimeNanoseconds
                let encoder = try context.backend.createCommandEncoder()
                let pass = try encoder.beginRenderPass(colorView: referenceMSView, resolveTargetView: referenceOutputView,
                    storeOp: .discard, clearColor: GPUColor(r: 0.07, g: 0.09, b: 0.12, a: 0.5))
                try context.reference.render(list: list, pass: pass, viewportPx: (UInt32(size.x), UInt32(size.y)),
                    coordinateSpace: (viewport.logical.x, viewport.logical.y))
                pass.end(); let buffer = try encoder.finish()
                let recorded = DispatchTime.now().uptimeNanoseconds
                context.backend.submit(buffer)
                return NativeUIFrameTiming(recordNanoseconds: recorded - start,
                    submitNanoseconds: DispatchTime.now().uptimeNanoseconds - recorded)
            }, finish: { try context.backend.waitUntilIdle() })
            let report = NativeUIBenchmarkReport(device: context.device.deviceName, width: size.x, height: size.y,
                work: NativeUIBenchmarkWork(vertices: list.vertices.count, indices: list.indices.count, draws: statistics.drawCalls),
                results: [native, reference])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let root = ProcessInfo.processInfo.environment["GUAVA_NATIVE_UI_BENCHMARK_OUTPUT"] ?? "/tmp/guava-native-ui-benchmark"
            let directory = URL(fileURLWithPath: root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("native-ui-m1-\(size.y).json")
            try encoder.encode(report).write(to: destination)
            print("UI benchmark report: \(destination.path)")
            for result in report.results {
                print("\(size): \(result.backend) CPU p50=\(result.cpuFrame.p50Microseconds) us completed p50=\(result.completedBatch.p50Microseconds) us/frame")
            }
        }
        #endif
    }

    private func tiled(_ source: DrawList) -> DrawList {
        let list = DrawList()
        for y in 0..<6 { for x in 0..<8 {
            let shifted = DrawList()
            let dx = Float(x * 160), dy = Float(y * 120)
            let vertices = source.vertices.map { vertex in
                var vertex = vertex; vertex.posX += dx; vertex.posY += dy; return vertex
            }
            let batches = source.batches.map { batch in
                var batch = batch
                if let clip = batch.scissor {
                    batch.scissor = UIRect(x: clip.x + dx, y: clip.y + dy, width: clip.width, height: clip.height)
                }
                return batch
            }
            shifted.load(vertices: vertices, indices: source.indices, batches: batches, resources: source.resources)
            list.append(shifted)
        } }
        return list
    }

    /// Complete every three frames on both APIs. This is batch throughput;
    /// it does not claim GPU timestamp duration or display FPS.
    private func measure(_ backend: String, render: () throws -> NativeUIFrameTiming, finish: () throws -> Void) throws -> NativeUIBenchmarkResult {
        for frame in 0..<30 { _ = try render(); if (frame + 1) % 3 == 0 { try finish() } }
        try finish()
        var cpu: [Double] = [], recorded: [Double] = [], submitted: [Double] = [], completed: [Double] = []
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            for frame in 0..<180 {
                let frameStart = DispatchTime.now().uptimeNanoseconds
                let timing = try render()
                cpu.append(Double(DispatchTime.now().uptimeNanoseconds - frameStart) / 1000)
                recorded.append(Double(timing.recordNanoseconds) / 1000)
                submitted.append(Double(timing.submitNanoseconds) / 1000)
                if (frame + 1) % 3 == 0 { try finish() }
            }
            completed.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 180 / 1000)
        }
        return NativeUIBenchmarkResult(backend: backend, cpuFrame: NativeUITiming(cpu), cpuRecord: NativeUITiming(recorded),
            cpuSubmit: NativeUITiming(submitted), completedBatch: NativeUITiming(completed))
    }
}
#endif
