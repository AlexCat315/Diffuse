#if canImport(Metal)
import Foundation
import Metal
import XCTest
@testable import NativeRHI

final class MetalSlangTests: XCTestCase {
    /// Compile fixtures through the exact offline path shipped to users.
    private func compile(_ fixture: String, entry: String, stage: ShaderStage) throws -> ShaderArtifact {
        guard let compiler = ProcessInfo.processInfo.environment["SLANGC"] else {
            throw XCTSkip("Set SLANGC to Slang 2026.19 to run compiler/GPU integration tests")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try XCTUnwrap(Bundle.module.url(forResource: fixture, withExtension: "slang", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = directory.appendingPathComponent("shader.json")
        let log = directory.appendingPathComponent("compiler.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("scripts/compile-rhi-shader.py").path,
            source.path, "--entry", entry, "--stage", stage.rawValue, "--target", "metal",
            "--slangc", compiler, "--output", artifact.path]
        if stage == .mesh { process.arguments! += ["--threadgroup-size", "3", "1", "1"] }
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            XCTFail(try String(contentsOf: log, encoding: .utf8))
            throw RHIError.invalidArgument("fixture compilation failed")
        }
        return try JSONDecoder().decode(ShaderArtifact.self, from: Data(contentsOf: artifact))
    }

    func testSlangComputeUsesReflectedEightThreadWorkgroups() throws {
        let artifact = try compile("compute", entry: "computeMain", stage: .compute)
        XCTAssertEqual(artifact.interface.threadgroupSize.x, 8)
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal]))
        let shader = try device.makeShaderModule(artifact.moduleDescriptor())
        let buffer = try device.makeBuffer(BufferDescriptor(size: 64, usage: [.storageWrite, .transferSource]))
        let target = try device.makeTexture(TextureDescriptor(width: 16, height: 1, format: .r32Uint,
            usage: [.transferDestination, .transferSource]))
        let binding = try device.makeBindingLayout(artifact.bindingLayoutDescriptor())
        let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [binding]))
        let set = try device.makeBindingSet(layout: binding, descriptor: BindingSetDescriptor(entries: [
            BindingSetEntry(slot: 0, resource: .storageBuffer(buffer: buffer))]))
        let pipeline = try device.makeComputePipeline(ComputePipelineDescriptor(layout: layout, shader: shader))
        let commands = CommandBuffer()
        commands.computePass {
            $0.setPipeline(pipeline)
            $0.setBindingSet(set)
            $0.dispatch(groupsX: 2)
        }
        commands.copyPass {
            $0.uploadBufferToTexture(buffer: buffer, bytesPerRow: 64, texture: target, width: 16, height: 1)
        }
        try device.beginFrame()
        try device.submit(commands)
        device.endFrame()
        try device.waitUntilIdle()
        var values = [UInt32](repeating: 0, count: 16)
        try values.withUnsafeMutableBytes {
            try device.readTextureData(target, width: 16, height: 1, bytesPerRow: 64, into: $0)
        }
        XCTAssertEqual(values, (7..<23).map(UInt32.init))
    }

    func testSlangMeshPipelineDrawsGreenTriangle() throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal]))
        guard device.capabilities.meshShading.mesh else { throw XCTSkip("No mesh shader GPU") }
        let mesh = try device.makeShaderModule(compile("mesh", entry: "meshMain", stage: .mesh).moduleDescriptor())
        let fragment = try device.makeShaderModule(compile("mesh", entry: "fragmentMain", stage: .fragment).moduleDescriptor())
        let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: []))
        var descriptor = MeshPipelineDescriptor(layout: layout, mesh: mesh)
        descriptor.fragment = fragment
        descriptor.colorAttachments = [ColorAttachmentDescriptor(format: .rgba8Unorm)]
        let pipeline = try device.makeMeshPipeline(descriptor)
        let target = try device.makeTexture(TextureDescriptor(width: 8, height: 8, format: .rgba8Unorm,
            usage: [.colorTarget, .transferSource]))
        let commands = CommandBuffer()
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [
            RenderColorTarget(texture: target, loadAction: .clear(SIMD4(1, 0, 0, 1)))])) {
            $0.setMeshPipeline(pipeline)
            $0.setViewport(Viewport(width: 8, height: 8))
            $0.drawMeshTasks(x: 1)
        }
        try device.beginFrame()
        try device.submit(commands)
        device.endFrame()
        try device.waitUntilIdle()
        var pixels = [UInt8](repeating: 0, count: 256)
        try pixels.withUnsafeMutableBytes {
            try device.readTextureData(target, width: 8, height: 8, bytesPerRow: 32, into: $0)
        }
        XCTAssertEqual(Array(pixels[(4 * 8 + 4) * 4..<(4 * 8 + 4) * 4 + 4]), [0, 255, 0, 255])
        XCTAssertEqual(pixels[0], 255)
    }
}
#endif
