import AssetPipeline
import Foundation
import NativeRHI
import RenderBackend

public enum NativePassBenchmark {
    public static func run(arguments: [String]) throws {
        let options = try PassBenchmarkOptions(arguments: arguments)
        try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
        if options.scene == .animated { AssetRegistry.shared.registerForTesting(AnimatedProbeScene.skinnedFixture(), at: 2) }
        defer { if options.scene == .animated { AssetRegistry.shared.unregisterTestingMesh(at: 2) } }
        let packet: RenderPacket
        switch options.scene {
        case .grid: packet = GridProbeScene.packet(size: options.size)
        case .mesh: packet = MeshProbeScene.packet(size: options.size)
        case .pbr: packet = PBRProbeScene.packet(size: options.size)
        case .post: packet = PostProbeScene.packet(size: options.size)
        case .stylized: packet = StylizedProbeScene.packet(size: options.size)
        case .particles: packet = ParticleProbeScene.packet(size: options.size)
        case .animated: packet = AnimatedProbeScene.packet(size: options.size)
        }
        func framePacket(_ frame: Int) -> RenderPacket {
            if options.scene == .particles { return ParticleProbeScene.packet(size: options.size,frame: frame) }
            if options.scene == .stylized { return StylizedProbeScene.packet(size: options.size,frame: frame) }
            if options.scene == .post { return PostProbeScene.packet(size: options.size,frame: frame) }
            if options.scene == .animated { return AnimatedProbeScene.packet(size: options.size,frame: frame) }
            var p = packet; p.frameIndex = frame
            // Exercise the complete HDR frame on both renderers. A static WGPU
            // view would reuse its opaque snapshot and measure a different workload.
            if options.scene == .pbr { p.scene.camera.eye.x += Float(frame % 11)*0.002 }
            return p
        }
        var results: [PassBenchmarkResult] = []
        var images: [String: Data] = [:]
        for api in options.backends {
            let device = try Device.make(DeviceConfig(preferredBackends: [api], enableValidation: false, framesInFlight: 3))
            let render: (Int) throws -> RenderFrameStats
            let readback: () throws -> Data
            if options.scene == .grid {
                let renderer = try NativeGridRenderer(device: device)
                render = { frame in let p = framePacket(frame); try renderer.renderChecked(packet: p); return renderer.lastFrameStats }
                readback = {
                    guard let texture = renderer.colorTexture else { throw RHIError.invalidArgument("benchmark produced no color") }
                    return try GridImage.readback(device: device, texture: texture, size: options.size)
                }
            } else {
                let renderer = try NativeRenderer(device: device)
                render = { frame in let p = framePacket(frame); try renderer.renderChecked(packet: p); return renderer.lastFrameStats }
                readback = {
                    guard let texture = renderer.colorTexture else { throw RHIError.invalidArgument("benchmark produced no color") }
                    return try GridImage.readback(device: device, texture: texture, size: options.size)
                }
            }
            let result = try measure(name: "native-\(api.rawValue)", device: device.deviceName, options: options,
                render: render, finish: { try device.waitUntilIdle() })
            images[result.backend] = try readback()
            results.append(result)
            print("\(result.backend): CPU p50 \(String(format: "%.1f", result.cpuFrame.p50Microseconds)) us, completed batch \(String(format: "%.3f", result.completedBatch.p50Microseconds / 1000)) ms/frame")
        }
        let renderReference: (Int) throws -> RenderFrameStats
        let finishReference: () throws -> Void
        let readReference: () throws -> Data
        if options.scene == .grid {
            let reference = try WGPUGridReference(size: options.size)
            renderReference = { frame in let p = framePacket(frame); return try reference.render(packet: p) }
            finishReference = { try reference.finish() }; readReference = { try reference.readback() }
        } else {
            let reference = try WGPUSceneReference()
            renderReference = { frame in
                let result = try reference.render(packet: framePacket(frame))
                if (options.scene == .pbr || options.scene == .animated || options.scene == .stylized) && reference.renderer.lastFrameUsedOpaqueCache {
                    throw RHIError.invalidArgument("scene reference unexpectedly reused an opaque snapshot")
                }
                return result
            }
            finishReference = { try reference.finish() }; readReference = { try reference.readback() }
        }
        let result = try measure(name: WGPUReferenceConfiguration.name, device: "wgpu-native \(WGPUReferenceConfiguration.preference.rawValue)", options: options,
            render: renderReference, finish: finishReference)
        let expected = try readReference(); images[result.backend] = expected; results.append(result)
        if options.scene == .post {
            for native in results where native.backend != result.backend {
                for kind in [RenderPassKind.ssao,.ssr,.taa,.bloom,.fxaa,.tonemap] {
                    guard native.passFrames[kind.rawValue] == result.passFrames[kind.rawValue],
                          (native.passFrames[kind.rawValue] ?? 0) > 0 else {
                        throw RHIError.invalidArgument("post benchmark pass workload differs: \(native.backend) \(kind)")
                    }
                }
            }
        }
        if options.scene == .stylized {
            for native in results where native.backend != result.backend {
                for kind in [RenderPassKind.outline,.inkPaperPost] {
                    guard native.passFrames[kind.rawValue] == result.passFrames[kind.rawValue],
                          native.passDraws[kind.rawValue] == result.passDraws[kind.rawValue],
                          (native.passDraws[kind.rawValue] ?? 0) > 0 else {
                        throw RHIError.invalidArgument("stylized benchmark workload differs: \(native.backend) \(kind)")
                    }
                }
            }
        }
        if options.scene == .particles {
            for native in results where native.backend != result.backend {
                guard native.particleWork == result.particleWork, native.particleWork.candidates > 0,
                      native.particleWork.indirectDraws > 0,
                      native.passFrames == result.passFrames, native.passDraws == result.passDraws else {
                    throw RHIError.invalidArgument("particle benchmark compute/indirect workloads differ: \(native.backend)")
                }
            }
        }
        var differences: [String: GridImageDifference] = [:]
        for (name, image) in images {
            try GridImage.writePPM(image, size: options.size, to: options.output.appendingPathComponent("\(name).ppm"))
            if name != result.backend { differences[name] = try GridImage.difference(image, expected) }
        }
        let report = PassBenchmarkReport(scene: options.scene.rawValue, size: options.size, frames: options.frames, warmup: options.warmup,
            repeats: options.repeats, results: results, imageDifferences: differences)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: options.output.appendingPathComponent("report.json"))
        print("report: \(options.output.appendingPathComponent("report.json").path)")
        for (name, difference) in differences {
            guard difference.meanAbsoluteChannelError < 0.5,
                  difference.pixelsOverThree < max(1, difference.pixelCount / 100) else {
                throw RHIError.invalidArgument("\(name) image differs from WGPU: \(difference)")
            }
        }
    }
    private static func measure(name: String, device: String, options: PassBenchmarkOptions,
                                render: (Int) throws -> RenderFrameStats, finish: () throws -> Void) throws -> PassBenchmarkResult {
        for frame in 0..<options.warmup { _ = try render(frame); if (frame + 1) % 3 == 0 { try finish() } }
        try finish()
        var passFrames: [String: Int] = [:], passDraws: [String: Int] = [:]
        var frameSamples: [Double] = [], encodeSamples: [Double] = [], submitSamples: [Double] = [], batches: [Double] = []
        var particleWork = PassParticleWork()
        for repetition in 0..<options.repeats {
            let start = DispatchTime.now().uptimeNanoseconds
            for frame in 0..<options.frames {
                let stats = try render(options.warmup + repetition * options.frames + frame)
                particleWork.add(stats)
                for (kind, draws) in stats.passDrawCallCounts {
                    passFrames[kind.rawValue, default: 0] += 1
                    passDraws[kind.rawValue, default: 0] += draws
                }
                frameSamples.append(Double(stats.cpuFrameTotalNS) / 1000)
                encodeSamples.append(Double(stats.cpuEncodeNS) / 1000)
                submitSamples.append(Double(stats.cpuSubmitNS) / 1000)
                if (frame + 1) % 3 == 0 { try finish() }
            }
            if options.frames % 3 != 0 { try finish() }
            batches.append(Double(DispatchTime.now().uptimeNanoseconds - start) / Double(options.frames) / 1000)
        }
        return PassBenchmarkResult(backend: name, device: device, cpuFrame: PassTimingDistribution(frameSamples),
            cpuEncode: PassTimingDistribution(encodeSamples), cpuSubmit: PassTimingDistribution(submitSamples),
            completedBatch: PassTimingDistribution(batches), passFrames: passFrames, passDraws: passDraws,particleWork: particleWork)
    }
}

private enum ProbeScene: String { case grid, mesh, pbr, animated, post, stylized, particles }

private struct PassBenchmarkOptions {
    var scene = ProbeScene.grid
    var size = RenderDrawableSize(width: 1280, height: 720)
    var frames = 180
    var warmup = 30
    var repeats = 3
    var backends: [GraphicsAPI] = NativeRHI.platformDefaultBackends
    var output = URL(fileURLWithPath: "/tmp/guava-native-grid")
    init(arguments: [String]) throws {
        guard arguments.count % 2 == 0 else { throw RHIError.invalidArgument("use --scene grid|mesh|pbr|animated|post|stylized|particles --width N --height N --frames N --warmup N --repeats N --backends metal|vulkan|dx12 --output DIR") }
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--scene":
                guard let scene = ProbeScene(rawValue: value) else { throw RHIError.invalidArgument("choose grid, mesh, pbr, animated, post, stylized or particles scene") }
                self.scene = scene
            case "--output": output = URL(fileURLWithPath: value)
            case "--backends":
                let names = value.split(separator: ","); backends = try names.map {
                    guard let api = GraphicsAPI(rawValue: String($0)) else { throw RHIError.invalidArgument("unknown backend \($0)") }; return api
                }
                guard !backends.isEmpty else { throw RHIError.invalidArgument("choose a backend") }
            case "--width", "--height", "--frames", "--warmup", "--repeats":
                guard let number = Int(value), number > 0, number <= 10000 else { throw RHIError.invalidArgument("positive bounded benchmark values required") }
                switch arguments[index] {
                case "--width": size.width = UInt32(number)
                case "--height": size.height = UInt32(number)
                case "--frames": frames = number
                case "--warmup": warmup = number
                default: repeats = number
                }
            default: throw RHIError.invalidArgument("unknown option \(arguments[index])")
            }
        }
    }
}

public struct PassTimingDistribution: Codable {
    public let p50Microseconds: Double
    public let p95Microseconds: Double
    public let sampleCount: Int
    init(_ values: [Double]) {
        let ordered = values.sorted()
        sampleCount = ordered.count
        p50Microseconds = ordered[max(0, Int(ceil(Double(ordered.count) * 0.50)) - 1)]
        p95Microseconds = ordered[max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)]
    }
}
public struct PassBenchmarkResult: Codable {
    public let backend: String
    public let device: String
    public let cpuFrame: PassTimingDistribution
    public let cpuEncode: PassTimingDistribution
    public let cpuSubmit: PassTimingDistribution
    /// Includes explicit GPU completion every three frames. This measures
    /// whole-batch throughput, not GPU timestamp duration or display FPS.
    public let completedBatch: PassTimingDistribution
    public let passFrames: [String: Int]
    public let passDraws: [String: Int]
    public let particleWork: PassParticleWork
}
public struct PassParticleWork: Codable, Equatable {
    public private(set) var candidates = 0
    public private(set) var batches = 0
    public private(set) var dispatchWorkgroups = 0
    public private(set) var indirectDraws = 0
    mutating func add(_ stats: RenderFrameStats) {
        candidates += stats.gpuParticleCullCandidateCount
        batches += stats.gpuParticleCullBatchCount
        dispatchWorkgroups += stats.gpuParticleCullDispatchWorkgroups
        indirectDraws += stats.gpuParticleIndirectDrawCount
    }
}
private struct PassBenchmarkReport: Encodable {
    let scene: String
    let size: RenderDrawableSize
    let frames: Int
    let warmup: Int
    let repeats: Int
    let results: [PassBenchmarkResult]
    let imageDifferences: [String: GridImageDifference]
    private let environment = PassBenchmarkEnvironment()
    enum CodingKeys: String, CodingKey { case scene, width, height, frames, warmup, repeats, results, imageDifferences, environment }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scene, forKey: .scene)
        try container.encode(size.width, forKey: .width); try container.encode(size.height, forKey: .height)
        try container.encode(frames, forKey: .frames); try container.encode(warmup, forKey: .warmup)
        try container.encode(repeats, forKey: .repeats); try container.encode(results, forKey: .results)
        try container.encode(imageDifferences, forKey: .imageDifferences)
        try container.encode(environment, forKey: .environment)
    }
}

private struct PassBenchmarkEnvironment: Encodable {
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    let measuredAt = ISO8601DateFormatter().string(from: Date())
    #if DEBUG
    let buildConfiguration = "debug"
    #else
    let buildConfiguration = "release"
    #endif
    let shaderCompiler = "Slang 2026.19"
    let validationEnabled = false
    let framesPerCompletedBatch = 3
    let timingMethod = "CPU durations and three-frame batch completion; no GPU timestamps or presentation"
}
