import Foundation
import NativeRHI

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeFailure(message) }
}

struct ProbeResult: Codable {
    let name: String
    let passed: Bool
    let detail: String
}

struct ProbeReport: Codable {
    let device: String
    let backend: String
    let results: [ProbeResult]
}

struct ProbeContext {
    let device: Device
    let artifacts: URL
    let output: URL

    func shader(_ name: String) throws -> ShaderArtifact {
        try JSONDecoder().decode(ShaderArtifact.self, from: Data(contentsOf: artifacts.appendingPathComponent(name + ".json")))
    }

    func submit(_ commands: CommandBuffer, queue: QueueClass = .graphics) throws {
        try device.beginFrame()
        do { try device.submit(commands, queue: queue) }
        catch { device.endFrame(); throw error }
        device.endFrame()
        try device.waitUntilIdle()
    }

    func read(_ texture: Texture, width: Int, height: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes {
            try device.readTextureData(texture, width: width, height: height, bytesPerRow: width * 4, into: $0)
        }
        return bytes
    }

    func writeImage(_ bytes: [UInt8], width: Int, height: Int, name: String) throws {
        var data = Data("P6\n\(width) \(height)\n255\n".utf8)
        for index in stride(from: 0, to: bytes.count, by: 4) { data.append(contentsOf: bytes[index..<index + 3]) }
        try data.write(to: output.appendingPathComponent(name + ".ppm"))
    }
}
