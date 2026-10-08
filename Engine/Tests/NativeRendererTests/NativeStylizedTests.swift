import AssetPipeline
import Foundation
import NativeRHI
import NativeRendererValidation
@testable import RenderBackend
import SceneRuntime
import SIMDCompat
import XCTest

final class NativeStylizedTests: XCTestCase {
    func testNonfiniteStyleRejectsBeforeFramePreparation() throws {
        var packet = PBRProbeScene.packet(size: .init(width: 64,height: 64))
        packet.renderSettings.enableStylizedCharacterShading = true
        packet.renderSettings.stylizedCharacterStyle.toonLevels.z = .nan
        XCTAssertThrowsError(try NativePacketValidation.validate(packet))
        packet.renderSettings.stylizedCharacterStyle = .colorfulInkCard
        _ = try NativePacketValidation.validate(packet)
        XCTAssertFalse(MeshOutlinePolicy.includes(bounds: (.zero,SIMD3(1,0,1))))
        XCTAssertTrue(MeshOutlinePolicy.includes(bounds: (.zero,SIMD3(1,1,1))))
    }
    #if os(macOS)
    func testMetalDefaultStylizedParity() throws { try defaults(.metal) }
    func testMetalStylizedMaterialsAnimationAndCacheParity() throws { try parity(.metal) }
    func testMetalStylizedThinBackfacesAndMirrors() throws { try backfaces(.metal) }
    #endif
    #if os(Windows) || os(Linux)
    func testVulkanDefaultStylizedParity() throws { try defaults(.vulkan) }
    func testVulkanStylizedMaterialsAnimationAndCacheParity() throws { try parity(.vulkan) }
    func testVulkanStylizedThinBackfacesAndMirrors() throws { try backfaces(.vulkan) }
    #endif
    private func defaults(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api],enableValidation: false))
        let renderer = try NativeRenderer(device: device), reference = try WGPUSceneReference(validation: true)
        var packet = PBRProbeScene.packet(size: .init(width: 320,height: 192))
        packet.renderSettings.enableStylizedCharacterShading = true
        _ = try compare(packet,renderer: renderer,reference: reference,label: "default")
        packet.frameIndex = 1; packet.renderSettings.stylizedCharacterStyle.paperGrainStrength = 0
        _ = try compare(packet,renderer: renderer,reference: reference,label: "no-grain")
    }
    private func backfaces(_ api: GraphicsAPI) throws {
        var mesh = BuiltinMesh.cube(color: SIMD3(repeating: 1))
        mesh.indices = stride(from: 0,to: mesh.indices.count,by: 3).flatMap { start -> [UInt32] in
            let triangle = Array(mesh.indices[start..<start+3])
            return triangle.allSatisfy { mesh.vertices[Int($0)*MeshAsset.vertexFloatCount+MeshAsset.normalFloatOffset+1] > 0.5 } ? triangle : []
        }
        for vertex in 0..<mesh.vertexCount { mesh.vertices[vertex*MeshAsset.vertexFloatCount+1] = 0 }
        AssetRegistry.shared.registerForTesting(mesh,at: 2)
        defer { AssetRegistry.shared.unregisterTestingMesh(at: 2) }
        let device = try Device.make(DeviceConfig(preferredBackends: [api],enableValidation: false))
        let renderer = try NativeRenderer(device: device), reference = try WGPUSceneReference(validation: true)
        var packet = MeshProbeScene.packet(size: .init(width: 128,height: 96))
        packet.renderSettings.enableStylizedCharacterShading = true
        packet.scene.camera = RenderCamera(eye: SIMD3(0,-3,4),target: .zero,near: 0.1,far: 100)
        packet.scene.instances = []
        let background = try compare(packet,renderer: renderer,reference: reference,label: "thin-background")
        for frame in 0..<4 {
            let doubleSided = frame % 2 == 1
            var model = matrix_identity_float4x4; model.columns.0.x = frame < 2 ? 1 : -1
            packet.frameIndex = frame+1
            packet.scene.instances = [RenderInstance(meshIndex: 2,transform: model,material: RenderMaterial(doubleSided: doubleSided))]
            let output = try compare(packet,renderer: renderer,reference: reference,label: "thin-\(frame)")
            let delta = try GridImage.difference(background,output)
            if doubleSided { XCTAssertGreaterThan(delta.pixelsOverThree,50) }
            else { XCTAssertEqual(delta.pixelsOverThree,0) }
            XCTAssertEqual(renderer.lastFrameStats.passDrawCallCounts[.outline],0)
        }
    }
    private func parity(_ api: GraphicsAPI) throws {
        var imported = try MeshProbeScene.importedFixture()
        for index in imported.materials.indices { imported.materials[index].normalTextureIndex = 0 }
        var thin = BuiltinMesh.cube(color: SIMD3(repeating: 1))
        for vertex in 0..<thin.vertexCount { thin.vertices[vertex*MeshAsset.vertexFloatCount+1] = 0 }
        var biased = BuiltinMesh.cube(color: SIMD3(repeating: 1))
        for vertex in 0..<biased.vertexCount { biased.vertices[vertex*MeshAsset.vertexFloatCount+MeshAsset.materialIndexFloatOffset] = 7 }
        for (index,asset) in [(2,imported),(3,AnimatedProbeScene.skinnedFixture()),(4,thin),(5,biased)] {
            AssetRegistry.shared.registerForTesting(asset,at: index)
        }
        defer { for index in 2...5 { AssetRegistry.shared.unregisterTestingMesh(at: index) } }
        let device = try Device.make(DeviceConfig(preferredBackends: [api],enableValidation: false,framesInFlight: 3))
        let renderer = try NativeRenderer(device: device), reference = try WGPUSceneReference(validation: true)
        var packet = PBRProbeScene.packet(size: .init(width: 256,height: 192))
        packet.renderSettings.enableEditorGrid = false
        let actor = EntityID(rawValue: 300), deformable = EntityID(rawValue: 301)
        for (index,mesh) in [2,3,4,5].enumerated() {
            var model = matrix_identity_float4x4; model.columns.3 = SIMD4(Float(index)*1.8-2.7,1.5,4,1)
            packet.scene.instances.append(RenderInstance(meshIndex: mesh,transform: model,
                material: RenderMaterial(doubleSided: mesh == 4),entity: mesh == 3 ? actor : nil))
        }
        var pane = matrix_identity_float4x4; pane.columns.3 = SIMD4(0,1.2,5,1)
        packet.scene.instances.append(RenderInstance(meshIndex: 0,transform: pane,
            material: RenderMaterial(baseColorFactor: SIMD4(0.3,0.6,0.9,0.3),alphaMode: .blend,doubleSided: true)))
        packet.jointPaletteMap.palettes[actor] = JointPalette(matrices: [matrix_identity_float4x4,matrix_identity_float4x4])
        packet.scene.deformableMeshes = [RenderDeformableMesh(entity: deformable,revision: 1,topologyRevision: 1,
            positions: [SIMD3(-1,3,2),SIMD3(1,3,2),SIMD3(0,4,2),SIMD3(0,3,3)],
            triangleIndices: [0,2,1,0,1,3,1,2,3,2,0,3])]
        packet.scene.instances.append(RenderInstance(meshIndex: 0,transform: matrix_identity_float4x4,entity: deformable))
        var snapshots: [Data] = []
        for frame in 0..<30 {
            packet.frameIndex = frame
            switch frame {
            case 1: packet.renderSettings.enableStylizedCharacterShading = true
            case 2: packet.renderSettings.stylizedCharacterStyle.materialBiasStrength = 0
            case 3: packet.renderSettings.stylizedCharacterStyle.materialBiasStrength = 1
            case 4: packet.renderSettings.stylizedCharacterStyle.outlineWidth = 0
            case 5: packet.renderSettings.stylizedCharacterStyle.outlineWidth = 0.12
            case 6: packet.renderSettings.stylizedCharacterStyle.paperGrainStrength = 0.15
            case 7:
                packet.renderSettings.stylizedCharacterStyle.toonLevels = SIMD4(0.12,0.3,0.8,0)
                packet.renderSettings.stylizedCharacterStyle.inkWashColor = SIMD4(0.7,0.85,1,1)
            case 8:
                packet.scene.lights = [RenderLight(type: .spot,position: SIMD3(3,4,5),direction: SIMD3(-1,-1,-1),
                    color: SIMD3(repeating: 1),intensity: 2,range: 12,spotInnerAngleRadians: 0.3,spotOuterAngleRadians: 0.9)]
            case 9: packet.scene.instances[packet.scene.instances.count-3].transform.columns.0.x = -1
            case 10:
                var joint = matrix_identity_float4x4; joint.columns.0 = SIMD4(0.8,0.6,0,0); joint.columns.1 = SIMD4(-0.6,0.8,0,0)
                packet.jointPaletteMap.palettes[actor] = JointPalette(matrices: [matrix_identity_float4x4,joint])
                packet.scene.deformableMeshes[0].revision += 1; packet.scene.deformableMeshes[0].positions[0].y += 0.4
            case 11: packet.jointPaletteMap.palettes[actor] = JointPalette(matrices: [matrix_identity_float4x4])
            case 12: packet.jointPaletteMap.palettes = [:]
            case 13: packet.jointPaletteMap.palettes[actor] = JointPalette(matrices: [matrix_identity_float4x4,matrix_identity_float4x4])
            case 14: packet.scene.camera.projection = .orthographic; packet.scene.camera.orthographicHeight = 14
            case 15: packet.drawableSize = .init(width: 192,height: 128)
            case 16: packet.drawableSize = .init(width: 320,height: 200)
            case 17: packet.renderSettings.stage = .r3ViewportInterop
            case 18: packet.renderSettings.stage = .r4LightingPBRShadow
            case 19:
                packet.renderSettings.stage = .r5PostProcess
                packet.renderSettings.enableSSAO = true; packet.renderSettings.enableSSR = true; packet.renderSettings.enableTAA = true
                packet.renderSettings.enableBloom = true; packet.renderSettings.enableFXAA = true
            case 20: packet.scene.camera.eye.x += 0.2
            case 28:
                var invalid = packet; invalid.renderSettings.stylizedCharacterStyle.paperGrainStrength = .infinity
                XCTAssertThrowsError(try renderer.renderChecked(packet: invalid))
            case 29: packet.renderSettings.enableStylizedCharacterShading = false
            default: break
            }
            snapshots.append(try compare(packet,renderer: renderer,reference: reference,label: "frame-\(frame)"))
            XCTAssertEqual(renderer.lastFrameUsedOpaqueCache,reference.renderer.lastFrameUsedOpaqueCache,"cache frame \(frame)")
            if frame == 1 {
                XCTAssertEqual(renderer.lastFrameStats.passDrawCallCounts[.outline],reference.renderer.lastFrameStats.passDrawCallCounts[.outline])
                XCTAssertLessThan(try XCTUnwrap(renderer.lastFrameStats.passDrawCallCounts[.outline]),try XCTUnwrap(renderer.lastFrameStats.passDrawCallCounts[.basePass]))
            }
            if frame == 17 { XCTAssertNil(renderer.lastFrameStats.passDrawCallCounts[.inkPaperPost]) }
            if frame == 27 { XCTAssertTrue(renderer.lastFrameUsedOpaqueCache); XCTAssertNil(renderer.lastFrameStats.passDrawCallCounts[.outline]) }
        }
        for (a,b) in [(0,1),(2,3),(4,5),(5,6)] {
            XCTAssertGreaterThan(try GridImage.difference(snapshots[a],snapshots[b]).pixelsOverThree,20,"stylized setting \(a)→\(b) must change pixels")
        }
    }
    private func compare(_ packet: RenderPacket, renderer: NativeRenderer, reference: WGPUSceneReference, label: String) throws -> Data {
        try renderer.renderChecked(packet: packet); _ = try reference.render(packet: packet)
        let native = try GridImage.readback(device: renderer.device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
        let expected = try reference.readback(), delta = try GridImage.difference(native,expected)
        let directory = URL(fileURLWithPath: "/tmp/guava-native-stylized")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        try GridImage.writePPM(native,size: packet.drawableSize,to: directory.appendingPathComponent("\(label).ppm"))
        try GridImage.writePPM(expected,size: packet.drawableSize,to: directory.appendingPathComponent("wgpu-\(label).ppm"))
        XCTAssertLessThan(delta.meanAbsoluteChannelError,0.5,"\(label): \(delta)")
        XCTAssertLessThan(delta.pixelsOverThree,max(1,delta.pixelCount/100),"\(label): \(delta)")
        return native
    }
}
