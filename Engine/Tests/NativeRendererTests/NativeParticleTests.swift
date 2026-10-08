import AssetPipeline
import Foundation
import NativeRHI
import NativeRendererValidation
@testable import RenderBackend
import SceneRuntime
import SIMDCompat
import XCTest

final class NativeParticleTests: XCTestCase {
    func testParticleInputAndBinaryLayouts() throws {
        XCTAssertEqual(MemoryLayout<GPUParticleInstance>.stride,112)
        XCTAssertEqual(MemoryLayout<ParticleUniforms>.stride,112)
        XCTAssertEqual(MemoryLayout<GPUParticleCullUniforms>.stride,80)
        XCTAssertEqual(MemoryLayout<GPUParticleCullBatch>.stride,16)
        XCTAssertEqual(MemoryLayout<GPUParticleIndirectDrawArgs>.stride,16)
        for api in [GraphicsAPI.metal,.vulkan] {
            let artifact = try NativeShaderLibrary.artifact(name: "particle_cull_compact",api: api,stage: .compute)
            XCTAssertEqual(artifact.interface.threadgroupSize,ThreadgroupSize(x: 64))
            XCTAssertEqual(artifact.interface.bindings.first { $0.slot == 1 }?.buffer.elementStride,112)
            XCTAssertEqual(artifact.interface.bindings.first { $0.slot == 2 }?.buffer.elementStride,16)
            XCTAssertEqual(artifact.interface.bindings.first { $0.slot == 4 }?.buffer.elementStride,16)
        }
        var packet = MeshProbeScene.packet(size: .init(width: 64,height: 64))
        packet.scene.particles = [RenderParticle(position: .zero,size: 1,color: SIMD4(repeating: 1))]
        _ = try NativePacketValidation.validate(packet)
        packet.scene.particles[0].textureVOffset = .nan
        XCTAssertThrowsError(try NativePacketValidation.validate(packet))
    }
    #if os(macOS)
    func testMetalParticleStableCompactionAndIndirectArguments() throws { try compaction(.metal) }
    func testMetalBillboardsRibbonsBlendingDepthTexturesAndCacheParity() throws { try parity(.metal) }
    #endif
    #if os(Windows) || os(Linux)
    func testVulkanParticleStableCompactionAndIndirectArguments() throws { try compaction(.vulkan) }
    func testVulkanBillboardsRibbonsBlendingDepthTexturesAndCacheParity() throws { try parity(.vulkan) }
    #endif
    private func compaction(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api],enableValidation: false))
        let pass = try NativeParticlePass(device: device)
        var scene = RenderScene(camera: RenderCamera(eye: SIMD3(0,0,5),target: .zero))
        let matrices = RenderCameraMatrices(projection: matrix_identity_float4x4,view: matrix_identity_float4x4,viewProjection: matrix_identity_float4x4)
        for count in [131,399,7] {
            scene.particles = (0..<count).map { index in
                RenderParticle(position: SIMD3(index % 3 == 0 ? 5 : 0,0,0),size: index % 11 == 0 ? 0 : 0.2,
                    color: SIMD4(Float(index)/Float(count),0.5,0.25,index % 7 == 0 ? 0 : 1),
                    blendMode: index < count/2 ? .alpha : .additive)
            }
            try device.beginFrame()
            let commands = CommandBuffer()
            let frame = try XCTUnwrap(pass.prepare(scene: scene,matrices: matrices,hdr: false,into: commands))
            try device.submit(commands); device.endFrame()
            let args = try readBuffer(device: device,buffer: frame.indirect,bytes: frame.draws.count*16)
            let visible = try readBuffer(device: device,buffer: XCTUnwrap(pass.buffers.visible),bytes: count*112)
            let batches = ParticleRenderBatchPlan(particles: scene.particles).batches
            for (batchIndex,batch) in batches.enumerated() {
                let range = batch.start..<(batch.start+batch.count)
                let selected: [Int] = range.filter { $0 % 3 != 0 && $0 % 11 != 0 && $0 % 7 != 0 }
                let values: [UInt32] = args.withUnsafeBytes { raw in (0..<4).map { raw.loadUnaligned(fromByteOffset: batchIndex*16+$0*4,as: UInt32.self) } }
                XCTAssertEqual(values,[6,UInt32(selected.count),0,UInt32(batch.start)])
                let expected = selected.map { GPUParticleInstance(particle: scene.particles[$0]) }.withUnsafeBytes { Data($0) }
                XCTAssertEqual(visible.subdata(in: batch.start*112..<(batch.start+selected.count)*112),expected)
            }
        }
    }
    private func readBuffer(device: Device, buffer: Buffer, bytes: Int) throws -> Data {
        let target = try device.makeTexture(TextureDescriptor(width: bytes/4,height: 1,format: .r32Uint,usage: [.transferDestination,.transferSource]))
        defer { device.destroy(target) }
        let commands = CommandBuffer()
        commands.copyPass { $0.uploadBufferToTexture(buffer: buffer,bytesPerRow: bytes,texture: target,width: bytes/4,height: 1) }
        try device.beginFrame(); try device.submit(commands); device.endFrame(); try device.waitUntilIdle()
        var data = Data(count: bytes)
        try data.withUnsafeMutableBytes { try device.readTextureData(target,width: bytes/4,height: 1,bytesPerRow: bytes,into: $0) }
        return data
    }
    private func parity(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api],enableValidation: false,framesInFlight: 3))
        let renderer = try NativeRenderer(device: device), reference = try WGPUSceneReference(validation: true)
        let textureURL = URL(fileURLWithPath: "/tmp/guava-native-particle-texture.bmp")
        let retryURL = URL(fileURLWithPath: "/tmp/guava-no-particle-texture")
        try? FileManager.default.removeItem(at: retryURL)
        try textureFixture().write(to: textureURL)
        defer { try? FileManager.default.removeItem(at: textureURL); try? FileManager.default.removeItem(at: retryURL) }
        var packet = MeshProbeScene.packet(size: .init(width: 256,height: 192))
        packet.renderSettings.enableEditorGrid = false; packet.renderSettings.debugViewMode = .unlit
        packet.scene.camera = RenderCamera(eye: SIMD3(0,0,7),target: .zero,near: 0.1,far: 100)
        packet.scene.instances = [RenderInstance(meshIndex: 0,transform: matrix_identity_float4x4)]
        packet.scene.particles = [
            RenderParticle(position: SIMD3(-1,0,1.2),size: 1.5,rotation: 0.4,color: SIMD4(0.9,0.3,0.2,0.8)),
            RenderParticle(position: SIMD3(1,0,1.3),size: 1.6,color: SIMD4(0.2,0.5,1,0.7),blendMode: .additive),
            RenderParticle(position: SIMD3(0,0,-1.2),size: 0.8,color: SIMD4(0,1,0,1)),
            RenderParticle(position: SIMD3(0,1.5,0),size: 1,color: SIMD4(0.9,0.8,0.2,0.7),endColor: SIMD4(0.2,0.1,0.9,0.1),
                alignmentAxis: SIMD3(1,1,0),stretch: 2,startSize: 0.6,endSize: 0.05,shape: .ribbonSegment,
                textureVOffset: 0.15,textureVScale: 2.3,texturePath: textureURL.path),
            RenderParticle(position: SIMD3(-2,-1.2,0),size: 0.7,color: SIMD4(0.3,0.9,0.7,0.6),
                alignmentAxis: SIMD3(1,0.5,0.1),stretch: 2.5,texturePath: textureURL.path),
            RenderParticle(position: SIMD3(2,-1.2,0),size: 0.7,color: SIMD4(0.8,0.2,0.9,0.6),texturePath: retryURL.path)
        ]
        let originals = packet.scene.particles
        var snapshots: [Data] = []
        for frame in 0..<26 {
            packet.frameIndex = frame
            switch frame {
            case 1: packet.scene.particles[1].blendMode = .alpha
            case 2: packet.scene.particles[0].texturePath = textureURL.path
            case 3: packet.scene.particles[0].uvRect = SIMD4(0,0,0.5,0.5)
            case 4: packet.scene.particles[0].rotation += 0.7
            case 5: packet.scene.particles[3].textureVScale = 0; packet.scene.particles[3].endColor = packet.scene.particles[3].color
            case 6: packet.scene.particles.reverse()
            case 7:
                packet.scene.particles += (0..<400).map { (index: Int) -> RenderParticle in
                    let position = SIMD3<Float>(Float(index % 20)*0.25-2.5,Float(index/20)*0.18-1.8,2)
                    return RenderParticle(position: position,size: 0.08,
                        color: SIMD4(1,0.5,0.1,0.5),blendMode: index % 3 == 0 ? .additive : .alpha)
                }
            case 8: packet.scene.particles = originals
            case 9: packet.drawableSize = .init(width: 192,height: 128)
            case 10: packet.drawableSize = .init(width: 320,height: 200)
            case 11: packet.scene.camera.projection = .orthographic; packet.scene.camera.orthographicHeight = 6
            case 12:
                packet.renderSettings.stage = .r5PostProcess
                packet.renderSettings.enableBloom = true; packet.renderSettings.enableTAA = true; packet.renderSettings.enableFXAA = true
            case 21: packet.scene.particles[0].position.x += 0.5
            case 22: packet.scene.particles = []
            case 23: packet.scene.particles = originals
            case 24:
                var invalid = packet; invalid.scene.particles[0].endColor.z = .infinity
                XCTAssertThrowsError(try renderer.renderChecked(packet: invalid))
                try textureFixture().write(to: retryURL)
            case 25: packet.renderSettings.stage = .r3ViewportInterop; packet.renderSettings.enableBloom = false; packet.renderSettings.enableTAA = false; packet.renderSettings.enableFXAA = false
            default: break
            }
            try renderer.renderChecked(packet: packet); _ = try reference.render(packet: packet)
            let native = try GridImage.readback(device: device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
            let expected = try reference.readback(), delta = try GridImage.difference(native,expected)
            XCTAssertLessThan(delta.meanAbsoluteChannelError,0.5,"frame \(frame): \(delta)")
            XCTAssertLessThan(delta.pixelsOverThree,max(1,delta.pixelCount/100),"frame \(frame): \(delta)")
            XCTAssertEqual(renderer.lastFrameStats.gpuParticleCullCandidateCount,packet.scene.particles.count)
            XCTAssertEqual(renderer.lastFrameStats.gpuParticleCullBatchCount,reference.renderer.lastFrameStats.gpuParticleCullBatchCount)
            XCTAssertEqual(renderer.lastFrameStats.gpuParticleIndirectDrawCount,reference.renderer.lastFrameStats.gpuParticleIndirectDrawCount)
            XCTAssertEqual(renderer.lastFrameUsedOpaqueCache,reference.renderer.lastFrameUsedOpaqueCache)
            if frame == 20 || frame == 21 || frame == 22 { XCTAssertTrue(renderer.lastFrameUsedOpaqueCache) }
            let directory = URL(fileURLWithPath: "/tmp/guava-native-particles")
            try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
            try GridImage.writePPM(native,size: packet.drawableSize,to: directory.appendingPathComponent("frame-\(frame).ppm"))
            try GridImage.writePPM(expected,size: packet.drawableSize,to: directory.appendingPathComponent("wgpu-\(frame).ppm"))
            snapshots.append(native)
        }
        for (a,b) in [(0,1),(1,2),(2,3),(3,4),(4,5),(20,21),(21,22),(22,23),(23,24)] {
            XCTAssertGreaterThan(try GridImage.difference(snapshots[a],snapshots[b]).pixelsOverThree,20,"particle change \(a)→\(b)")
        }
    }
    private func textureFixture() -> Data {
        // A 2×2, bottom-up BGRA BMP exercises the real production decoder.
        var data = Data([0x42,0x4d])
        func append(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        append(70); append(0); append(54); append(40); append(2); append(2)
        data.append(contentsOf: [1,0,32,0]); append(0); append(16); append(0); append(0); append(0); append(0)
        data.append(contentsOf: [255,32,16,255,16,255,32,255,16,32,255,255,255,255,255,128])
        return data
    }
}
