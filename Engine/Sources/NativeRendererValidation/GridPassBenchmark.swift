import Foundation
import NativeRHI
import RenderBackend

public enum GridPassBenchmark {
    public static func run(arguments: [String]) throws {
        let options = try GridBenchmarkOptions(arguments: arguments)
        try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
        let packet = GridProbeScene.packet(size: options.size)
        var results: [GridBenchmarkResult] = []
        var images: [String: Data] = [:]
        for api in options.backends {
            let device = try Device.make(DeviceConfig(preferredBackends: [api], enableValidation: false, framesInFlight: 3))
            let renderer = try NativeGridRenderer(device: device)
            let result = try measure(name: "native-\(api.rawValue)", device: device.deviceName, options: options,
                render: { frame in var p = packet; p.frameIndex = frame; try renderer.renderChecked(packet: p); return renderer.lastFrameStats },
                finish: { try device.waitUntilIdle() })
            guard let texture = renderer.colorTexture else { throw RHIError.invalidArgument("benchmark produced no color") }
            images[result.backend] = try GridImage.readback(device: device, texture: texture, size: options.size)
            results.append(result)
            print("\(result.backend): CPU p50 \(String(format: "%.1f", result.cpuFrame.p50Microseconds)) us, completed batch \(String(format: "%.3f", result.completedBatch.p50Microseconds / 1000)) ms/frame")
        }
        let reference = try WGPUGridReference(size: options.size)
        let result = try measure(name: "wgpu-metal", device: "wgpu-native Metal", options: options,
            render: { frame in var p = packet; p.frameIndex = frame; return try reference.render(packet: p) },
            finish: { try reference.finish() })
        let expected = try reference.readback(); images[result.backend] = expected; results.append(result)
        var differences: [String: GridImageDifference] = [:]
        for (name, image) in images {
            try GridImage.writePPM(image, size: options.size, to: options.output.appendingPathComponent("\(name).ppm"))
            if name != result.backend { differences[name] = try GridImage.difference(image, expected) }
        }
        let report = GridBenchmarkReport(size: options.size, frames: options.frames, warmup: options.warmup,
            repeats: options.repeats, results: results, imageDifferences: differences)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: options.output.appendingPathComponent("report.json"))
        print("report: \(options.output.appendingPathComponent("report.json").path)")
        for (name, difference) in differences {
            guard difference.meanAbsoluteChannelError < 0.5,
                  difference.pixelsOverThree < max(1, difference.pixelCount / 100) else {
                throw RHIError.invalidArgument("\(name) grid differs from WGSL: \(difference)")
            }
        }
    }
    private static func measure(name: String, device: String, options: GridBenchmarkOptions,
                                render: (Int) throws -> RenderFrameStats, finish: () throws -> Void) throws -> GridBenchmarkResult {
        for frame in 0..<options.warmup { _ = try render(frame); if (frame + 1) % 3 == 0 { try finish() } }
        try finish()
        var frameSamples: [Double] = [], encodeSamples: [Double] = [], submitSamples: [Double] = [], batches: [Double] = []
        for repetition in 0..<options.repeats {
            let start = DispatchTime.now().uptimeNanoseconds
            for frame in 0..<options.frames {
                let stats = try render(options.warmup + repetition * options.frames + frame)
                frameSamples.append(Double(stats.cpuFrameTotalNS) / 1000)
                encodeSamples.append(Double(stats.cpuEncodeNS) / 1000)
                submitSamples.append(Double(stats.cpuSubmitNS) / 1000)
                if (frame + 1) % 3 == 0 { try finish() }
            }
            if options.frames % 3 != 0 { try finish() }
            batches.append(Double(DispatchTime.now().uptimeNanoseconds - start) / Double(options.frames) / 1000)
        }
        return GridBenchmarkResult(backend: name, device: device, cpuFrame: GridTimingDistribution(frameSamples),
            cpuEncode: GridTimingDistribution(encodeSamples), cpuSubmit: GridTimingDistribution(submitSamples),
            completedBatch: GridTimingDistribution(batches))
    }
}

private struct GridBenchmarkOptions {
    var size = RenderDrawableSize(width: 1280, height: 720)
    var frames = 180
    var warmup = 30
    var repeats = 3
    var backends: [GraphicsAPI] = [.metal, .vulkan]
    var output = URL(fileURLWithPath: "/tmp/guava-native-grid")
    init(arguments: [String]) throws {
        guard arguments.count % 2 == 0 else { throw RHIError.invalidArgument("use --width N --height N --frames N --warmup N --repeats N --backends metal,vulkan --output DIR") }
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let value = arguments[index + 1]
            switch arguments[index] {
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

public struct GridTimingDistribution: Codable {
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
public struct GridBenchmarkResult: Codable {
    public let backend: String
    public let device: String
    public let cpuFrame: GridTimingDistribution
    public let cpuEncode: GridTimingDistribution
    public let cpuSubmit: GridTimingDistribution
    /// Includes explicit GPU completion every three frames. This measures
    /// whole-batch throughput, not GPU timestamp duration or display FPS.
    public let completedBatch: GridTimingDistribution
}
private struct GridBenchmarkReport: Encodable {
    let size: RenderDrawableSize
    let frames: Int
    let warmup: Int
    let repeats: Int
    let results: [GridBenchmarkResult]
    let imageDifferences: [String: GridImageDifference]
    private let environment = GridBenchmarkEnvironment()
    enum CodingKeys: String, CodingKey { case width, height, frames, warmup, repeats, results, imageDifferences, environment }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(size.width, forKey: .width); try container.encode(size.height, forKey: .height)
        try container.encode(frames, forKey: .frames); try container.encode(warmup, forKey: .warmup)
        try container.encode(repeats, forKey: .repeats); try container.encode(results, forKey: .results)
        try container.encode(imageDifferences, forKey: .imageDifferences)
        try container.encode(environment, forKey: .environment)
    }
}

private struct GridBenchmarkEnvironment: Encodable {
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
