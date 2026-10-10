#if os(macOS)
import Foundation
import NativeRHI
import RHIWGPU
import Testing
@testable import GuavaUIRuntime

private struct NativeUITiming: Encodable {
    let p50Microseconds: Double
    let p95Microseconds: Double
    let sampleCount: Int
    init(_ samples: [Double]) {
        let sorted = samples.sorted(); sampleCount = samples.count
        p50Microseconds = sorted[Int(ceil(Double(sorted.count) * 0.5)) - 1]
        p95Microseconds = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
    }
}

private struct NativeUIBenchmarkResult: Encodable {
    let backend: String
    let cpuFrame: NativeUITiming
    let cpuRecord: NativeUITiming
    let cpuSubmit: NativeUITiming
    let completedBatch: NativeUITiming
    let nativeSubmissionPhases: NativeUISubmissionPhases?
    let blocks: [NativeUIBenchmarkBlock]
}

private struct NativeUISubmissionPhases: Encodable {
    let validation: NativeUITiming
    let planning: NativeUITiming
    let encoding: NativeUITiming
    let queueSubmit: NativeUITiming
    let passSetup: NativeUITiming
    let encoderCreation: NativeUITiming
    let commandReplay: NativeUITiming
    let bindingApply: NativeUITiming
    /// Minimum planning time across the measured frames. If this is far below
    /// `planning.p50`, the per-frame planning collapses after the first frame
    /// (steady state); if it tracks p50, planning re-runs in full every frame.
    let planningMinMicroseconds: Double

    init(_ profiles: [SubmissionCPUProfile]) {
        validation = NativeUITiming(profiles.map { Double($0.validationNanoseconds) / 1000 })
        planning = NativeUITiming(profiles.map { Double($0.planningNanoseconds) / 1000 })
        encoding = NativeUITiming(profiles.map { Double($0.encodingNanoseconds) / 1000 })
        queueSubmit = NativeUITiming(profiles.map { Double($0.queueSubmitNanoseconds) / 1000 })
        passSetup = NativeUITiming(profiles.map { Double($0.passSetupNanoseconds) / 1000 })
        encoderCreation = NativeUITiming(profiles.map { Double($0.encoderCreationNanoseconds) / 1000 })
        commandReplay = NativeUITiming(profiles.map { Double($0.commandReplayNanoseconds) / 1000 })
        bindingApply = NativeUITiming(profiles.map { Double($0.bindingApplyNanoseconds) / 1000 })
        planningMinMicroseconds = profiles.map { Double($0.planningNanoseconds) / 1000 }.min() ?? 0
    }
}

/// Each index identifies the same paired block in both backend reports.
private struct NativeUIBenchmarkBlock: Encodable {
    let cpuFrame: NativeUITiming
    let cpuRecord: NativeUITiming
    let cpuSubmit: NativeUITiming
    let completedMicroseconds: Double
}

private struct NativeUIBenchmarkBackend {
    let name: String
    let render: () throws -> NativeUIFrameTiming
    let finish: () throws -> Void
}

private struct NativeUIBenchmarkSamples {
    var cpu: [Double] = []
    var recorded: [Double] = []
    var submitted: [Double] = []
    var completed: [Double] = []
    var blocks: [NativeUIBenchmarkBlock] = []
    var profiles: [SubmissionCPUProfile] = []

    mutating func measure(_ backend: NativeUIBenchmarkBackend) throws {
        try backend.finish()
        let sampleStart = cpu.count
        let start = DispatchTime.now().uptimeNanoseconds
        for frame in 0..<180 {
            let frameStart = DispatchTime.now().uptimeNanoseconds
            let timing = try backend.render()
            cpu.append(Double(DispatchTime.now().uptimeNanoseconds - frameStart) / 1000)
            recorded.append(Double(timing.recordNanoseconds) / 1000)
            submitted.append(Double(timing.submitNanoseconds) / 1000)
            if let profile = timing.profile { profiles.append(profile) }
            if (frame + 1) % 3 == 0 { try backend.finish() }
        }
        let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 180 / 1000
        completed.append(duration)
        blocks.append(NativeUIBenchmarkBlock(cpuFrame: NativeUITiming(Array(cpu[sampleStart...])),
            cpuRecord: NativeUITiming(Array(recorded[sampleStart...])), cpuSubmit: NativeUITiming(Array(submitted[sampleStart...])),
            completedMicroseconds: duration))
    }
    func result(_ name: String) -> NativeUIBenchmarkResult {
        NativeUIBenchmarkResult(backend: name, cpuFrame: NativeUITiming(cpu), cpuRecord: NativeUITiming(recorded),
            cpuSubmit: NativeUITiming(submitted), completedBatch: NativeUITiming(completed),
            nativeSubmissionPhases: profiles.isEmpty ? nil : NativeUISubmissionPhases(profiles), blocks: blocks)
    }
}

private struct NativeUIFrameTiming {
    let recordNanoseconds: UInt64
    let submitNanoseconds: UInt64
    var profile: SubmissionCPUProfile? = nil
}

private struct NativeUIBenchmarkScopes: Encodable {
    let nativeRecord = "UI preparation and abstract command recording"
    let nativeSubmit = "validation, dependency planning, native encoding and queue submission; includes frame acknowledgment/end"
    let wgpuRecord = "UI preparation, abstract recording and CommandEncoder.finish (validation, local tracking, native encoding)"
    let wgpuSubmit = "global state reconciliation, pending writes, lifetime tracking and queue submission"
    let comparableCPU = "cpuFrame includes frame setup and recording/submission; excludes explicit three-frame GPU drains"
    let nativePhaseProfiling = ProcessInfo.processInfo.environment["GUAVA_NATIVE_SUBMISSION_PROFILE"] == "1"
}

private struct NativeUIBenchmarkWork: Encodable {
    let vertices: Int
    let indices: Int
    let draws: Int
    let imageAssets: Int
    let imageAssetBytes: Int
}

private struct NativeUIBenchmarkUploads: Encodable {
    let initialBytes: Int
    let steadyStateBytes: Int
}

private struct NativeUIBenchmarkReport: Encodable {
    let device: String
    let scenario: String
    let width: Int
    let height: Int
    let samples = 4
    let format = "bgra8UnormSRGB"
    let frames = 180
    let warmup = 60
    let repeats = 6
    let schedule = "paired blocks with alternating first backend"
    let measurementScopes = NativeUIBenchmarkScopes()
    let work: NativeUIBenchmarkWork
    let nativeUploads: NativeUIBenchmarkUploads
    let results: [NativeUIBenchmarkResult]
}

@Suite("Native draw list release benchmark", .serialized)
struct NativeDrawListBenchmarkTests {
    /// Fixed geometry, no authored image assets: varies command count while
    /// avoiding a growing vertex upload or texture working set.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GUAVA_NATIVE_COMMAND_BENCHMARK"] == "1"))
    func commandScaling() throws {
        #if DEBUG
        throw RHIError.invalidArgument("run the command benchmark with swift test -c release")
        #else
        let context = try NativeUIDrawTestContext(validation: false)
        let geometry = DrawList()
        geometry.addRoundedRect(UIRect(x: 0, y: 0, width: 1280, height: 720), radius: 0,
            color: Color(r: 0.3, g: 0.5, b: 0.7, a: 1))
        for count in [0, 1, 96, 1024] {
            let list = DrawList()
            if count > 0 {
                let batch = try #require(geometry.batches.first)
                let batches = (0..<count).map { index in
                    var value = batch
                    value.scissor = UIRect(x: Float(index % 32) * 32, y: Float(index / 32) * 18, width: 32, height: 18)
                    return value
                }
                list.load(vertices: geometry.vertices, indices: geometry.indices, batches: batches)
            }
            try run(context, list: list, name: "native-command-count-\(count)")
        }
        #endif
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GUAVA_NATIVE_UI_BENCHMARK"] == "1"))
    func equivalentWork() throws {
        #if DEBUG
        throw RHIError.invalidArgument("run the UI benchmark with swift test -c release")
        #else
        let context = try NativeUIDrawTestContext(validation: false)
        let scene = try nativeUIScene(context)
        try run(context, list: tiled(scene), name: "native-ui")
        #endif
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GUAVA_NATIVE_IMAGE_BENCHMARK"] == "1"))
    func ownedImages() throws {
        #if DEBUG
        throw RHIError.invalidArgument("run the image benchmark with swift test -c release")
        #else
        let context = try NativeUIDrawTestContext(validation: false)
        let registry = ImageAssetRegistry(), list = DrawList()
        for row in 0..<8 { for column in 0..<12 {
            let index = row * 12 + column
            var pixels: [UInt8] = []
            for y in 0..<64 { for x in 0..<64 {
                pixels.append(contentsOf: [UInt8((index * 17 + x * 3) % 256), UInt8((index * 29 + y * 3) % 256),
                    UInt8((x * 2 + y * 2) % 256), UInt8(128 + ((x / 8 + y / 8) % 2) * 127)])
            } }
            let asset = try registry.register(key: "tile-\(index)", decoded: .init(pixels: pixels, width: 64, height: 64))
            list.retainResource(asset)
            list.addRoundedImageQuad(rect: UIRect(x: Float(column * 106 + 2), y: Float(row * 90 + 2), width: 102, height: 86),
                radius: 8, textureID: asset.textureID, tint: Color(r: 0.9, g: 0.8, b: 1, a: 0.9))
        } }
        #expect(list.resources.count == 96)
        try run(context, list: list, name: "native-ui-image-assets")
        #endif
    }

    private func run(_ context: NativeUIDrawTestContext, list: DrawList, name: String) throws {
        let format = NativeUITestFormat.cases[3]
        let profileEnabled = ProcessInfo.processInfo.environment["GUAVA_NATIVE_SUBMISSION_PROFILE"] == "1"
        var assetCount = 0, assetBytes = 0
        list.resources.forEach(of: ImageAssetRegistry.Asset.self) { asset in
            assetCount += 1; assetBytes += asset.image.pixels.count
        }
        for size in [SIMD2(1280, 720), SIMD2(1920, 1080), SIMD2(2560, 1440), SIMD2(3840, 2160)] {
            let viewport = NativeUIViewport(pixels: size, logical: SIMD2(1280, 720))
            let (actual, statistics) = try context.nativeImage(list: list, format: format, samples: 4, viewport: viewport)
            let expected = try context.referenceImage(list: list, format: format, samples: 4, viewport: viewport)
            try expectNativeUIParity(actual, expected, format: format, label: "benchmark/\(size)")
            // Native now coalesces runs of same-texture batches into single draws,
            // so its draw count is at most the batch count (and far below it once
            // image assets share an atlas or solids share the fallback).
            #expect(statistics.drawCalls <= list.batches.filter { $0.indexCount > 0 && $0.scissor?.width != 0 }.count)
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
            let native = NativeUIBenchmarkBackend(name: "native-metal", render: {
                try context.device.beginFrame()
                do {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let commands = CommandBuffer()
                    let frame = try context.native.record(list: list, into: commands, target: target, viewport: viewport)
                    guard frame.statistics.textureUploads == 0 && frame.statistics.drawCalls == statistics.drawCalls else {
                        throw RHIError.invalidArgument("steady-state native UI work changed or reuploaded textures")
                    }
                    lastStatistics = frame.statistics
                    let recorded = DispatchTime.now().uptimeNanoseconds
                    let profile = profileEnabled ? SubmissionCPUProfile(recordsEncodingDetail: true) : nil
                    try context.device.submit(commands, cpuProfile: profile); frame.didSubmit()
                    context.device.endFrame()
                    return NativeUIFrameTiming(recordNanoseconds: recorded - start,
                        submitNanoseconds: DispatchTime.now().uptimeNanoseconds - recorded, profile: profile)
                } catch { context.device.endFrame(); throw error }
            }, finish: { try context.device.waitUntilIdle() })
            let reference = NativeUIBenchmarkBackend(name: "wgpu-metal", render: {
                let start = DispatchTime.now().uptimeNanoseconds
                let encoder = try context.backend.createCommandEncoder()
                let pass = try encoder.beginRenderPass(colorView: referenceMSView, resolveTargetView: referenceOutputView,
                    storeOp: .discard, clearColor: GPUColor(r: 0.07, g: 0.09, b: 0.12, a: 0.5))
                let draws = try context.reference.render(list: list, pass: pass, viewportPx: (UInt32(size.x), UInt32(size.y)),
                    coordinateSpace: (viewport.logical.x, viewport.logical.y))
                // The reference (wgpu) renderer still emits one draw per batch; it
                // is the native baseline we compare against, not a coalescing peer.
                guard draws == list.batches.filter({ $0.indexCount > 0 && $0.scissor?.width != 0 }).count else {
                    throw RHIError.invalidArgument("reference UI draw count changed")
                }
                pass.end(); let buffer = try encoder.finish()
                let recorded = DispatchTime.now().uptimeNanoseconds
                context.backend.submit(buffer)
                return NativeUIFrameTiming(recordNanoseconds: recorded - start,
                    submitNanoseconds: DispatchTime.now().uptimeNanoseconds - recorded)
            }, finish: { try context.backend.waitUntilIdle() })
            let results = try measurePair(native, reference)
            #expect(lastStatistics.drawCalls == statistics.drawCalls && lastStatistics.textureUploads == 0)
            let report = NativeUIBenchmarkReport(device: context.device.deviceName, scenario: name, width: size.x, height: size.y,
                work: NativeUIBenchmarkWork(vertices: list.vertices.count, indices: list.indices.count, draws: statistics.drawCalls,
                    imageAssets: assetCount, imageAssetBytes: assetBytes),
                nativeUploads: NativeUIBenchmarkUploads(initialBytes: statistics.textureUploadBytes, steadyStateBytes: lastStatistics.textureUploadBytes),
                results: results)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let root = ProcessInfo.processInfo.environment["GUAVA_NATIVE_UI_BENCHMARK_OUTPUT"] ?? "/tmp/guava-native-ui-benchmark"
            let directory = URL(fileURLWithPath: root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("\(name)-m1-\(size.y).json")
            try encoder.encode(report).write(to: destination)
            print("UI benchmark report: \(destination.path)")
            for result in report.results {
                print("\(size): \(result.backend) CPU p50=\(result.cpuFrame.p50Microseconds) us completed p50=\(result.completedBatch.p50Microseconds) us/frame")
            }
        }
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

    /// Alternate the first backend of six equal blocks so one API does not
    /// consistently receive the colder CPU/GPU or the earlier scheduler slot.
    private func measurePair(_ native: NativeUIBenchmarkBackend, _ reference: NativeUIBenchmarkBackend) throws -> [NativeUIBenchmarkResult] {
        for backend in [native, reference] {
            for frame in 0..<60 { _ = try backend.render(); if (frame + 1) % 3 == 0 { try backend.finish() } }
            try backend.finish()
        }
        var a = NativeUIBenchmarkSamples(), b = NativeUIBenchmarkSamples()
        for block in 0..<6 {
            if block.isMultiple(of: 2) { try a.measure(native); try b.measure(reference) }
            else { try b.measure(reference); try a.measure(native) }
        }
        return [a.result(native.name), b.result(reference.name)]
    }
}
#endif
