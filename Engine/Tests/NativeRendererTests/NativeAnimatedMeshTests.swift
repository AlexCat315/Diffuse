import AssetPipeline
import Foundation
import NativeRHI
import NativeRendererValidation
@testable import RenderBackend
import SceneRuntime
import SIMDCompat
import XCTest

final class NativeAnimatedMeshTests: XCTestCase {
    func testNonFinitePaletteRejected() throws {
        var packet = MeshProbeScene.packet(size: .init(width: 64,height: 64))
        var matrix = matrix_identity_float4x4; matrix.columns.0.x = .nan
        packet.jointPaletteMap = JointPaletteMap(palettes: [EntityID(rawValue: 1): JointPalette(matrices: [matrix])])
        XCTAssertThrowsError(try NativePacketValidation.validate(packet))
    }

    #if os(macOS)
    func testMetalTransparentOrderingDepthAndHDR() throws { try transparency(.metal) }
    func testMetalSkinningPaletteResetAndShadows() throws { try skinning(.metal) }
    func testMetalDeformableRevisionTopologyAndRollback() throws { try deformation(.metal) }
    #endif
    #if os(Windows) || os(Linux)
    func testVulkanTransparentOrderingDepthAndHDR() throws { try transparency(.vulkan) }
    func testVulkanSkinningPaletteResetAndShadows() throws { try skinning(.vulkan) }
    func testVulkanDeformableRevisionTopologyAndRollback() throws { try deformation(.vulkan) }
    #endif

    private func transparency(_ api: GraphicsAPI) throws {
        AssetRegistry.shared.registerForTesting(Self.quad(), at: 2)
        defer { AssetRegistry.shared.unregisterTestingMesh(at: 2) }
        let device = try Self.device(api), renderer = try NativeRenderer(device: device)
        let reference = try WGPUSceneReference(validation: true)
        var packet = Self.packet()
        // The near pane is laterally offset: Euclidean-distance sorting would
        // invert these panes, while camera-axis depth keeps them correct.
        packet.scene.instances = [Self.pane(z: 2,color: SIMD4(0.2,0.7,0.2,0.5),blend: true,x: 4),
            Self.pane(z: 0,color: SIMD4(0.7,0.2,0.2,1)),
            Self.pane(z: 1,color: SIMD4(0.2,0.2,0.7,0.5),blend: true)]
        var snapshots: [Data] = []
        for frame in 0..<7 {
            packet.frameIndex = frame
            if frame == 1 { packet.scene.instances.reverse() }
            if frame == 2 { packet.renderSettings.stage = .r4LightingPBRShadow }
            if frame == 3 {
                packet.renderSettings.enableEditorGrid = true
                packet.scene.instances[0].transform.columns.0.x *= -1
            }
            if frame == 4 {
                // A back-facing pane must render when double sided.
                packet.scene.instances[2].transform.columns.2.z = -1
                packet.scene.instances[2].material.doubleSided = true
            }
            if frame == 5 { packet.scene.instances[1].transform.columns.3.z = 3 }
            snapshots.append(try compare(packet,renderer: renderer,reference: reference,label: "transparent-\(frame)"))
            XCTAssertEqual(renderer.lastFrameStats.passDrawCallCounts[.depthPrepass],renderer.lastFrameUsedOpaqueCache ? nil : 1)
            XCTAssertEqual(renderer.lastFrameStats.passDrawCallCounts[.basePass],renderer.lastFrameUsedOpaqueCache ? nil : 1)
            XCTAssertEqual(renderer.lastFrameStats.passDrawCallCounts[.transparentMeshes],2)
            XCTAssertEqual(renderer.lastFrameStats.instancedMeshBatchCount,0)
            if frame >= 2 { XCTAssertEqual(renderer.lastFrameStats.passDrawCallCounts[.shadowPass],renderer.lastFrameUsedOpaqueCache ? nil : 1) }
            XCTAssertEqual(renderer.lastFrameUsedOpaqueCache,reference.renderer.lastFrameUsedOpaqueCache)
        }
        XCTAssertEqual(snapshots[0],snapshots[1],"input order cannot change transparent composition")
        XCTAssertEqual(snapshots[5],snapshots[6],"a new frame must clear the previous transparent composition")
        XCTAssertGreaterThan(try GridImage.difference(snapshots[4],snapshots[5]).pixelsOverThree,100)
    }

    private func skinning(_ api: GraphicsAPI) throws {
        AssetRegistry.shared.registerForTesting(Self.quad(joint: 1), at: 2)
        defer { AssetRegistry.shared.unregisterTestingMesh(at: 2) }
        let device = try Self.device(api), renderer = try NativeRenderer(device: device)
        let reference = try WGPUSceneReference(validation: true)
        let a = EntityID(rawValue: 41), b = EntityID(rawValue: 42)
        var packet = Self.packet(); packet.renderSettings.stage = .r4LightingPBRShadow
        packet.renderSettings.debugViewMode = .shaded
        packet.scene.instances = [Self.pane(z: 0,color: SIMD4(0.7,0.3,0.1,1),entity: a,scale: 1),
            Self.pane(z: 0,color: SIMD4(0.2,0.6,0.8,1),entity: b,scale: 1),
            Self.pane(z: -1,color: SIMD4(0.45,0.45,0.45,1),scale: 4)]
        packet.jointPaletteMap = JointPaletteMap(palettes: [
            a: JointPalette(matrices: [matrix_identity_float4x4,Self.translation(-1.4,0,0)]),
            b: JointPalette(matrices: [matrix_identity_float4x4,Self.translation(1.4,0,0)])])
        var snapshots: [Data] = []
        for frame in 0..<11 {
            packet.frameIndex = frame
            switch frame {
            case 1:
                var pose = Self.translation(-0.5,0.7,0)
                pose.columns.0 = SIMD4(cos(0.35),0,-sin(0.35),0)
                pose.columns.2 = SIMD4(sin(0.35),0,cos(0.35),0)
                packet.jointPaletteMap.palettes[a] = JointPalette(matrices: [matrix_identity_float4x4,pose])
            case 2: packet.jointPaletteMap.palettes[a] = .identity // joint 1 is now out of bounds
            case 3: packet.jointPaletteMap.palettes[a] = JointPalette()
            case 4: packet.jointPaletteMap.palettes.removeValue(forKey: a)
            case 5: packet.jointPaletteMap.palettes[a] = JointPalette(matrices: [matrix_identity_float4x4,Self.translation(-1.4,0,0)])
            case 6:
                packet.scene.instances[0].transform.columns.3.x = 20
                packet.jointPaletteMap.palettes[a] = JointPalette(matrices: [Self.translation(-20,0,0),Self.translation(-20,0,0)])
                packet.renderSettings.enableFrustumCulling = true
                packet.renderSettings.enableDistanceLOD = true
            case 7:
                packet.scene.instances[0].material.alphaMode = .blend
                packet.scene.instances[0].material.baseColorFactor.w = 0.5
            case 8: packet.renderSettings.debugViewMode = .worldNormal
            case 9:
                packet.renderSettings.debugViewMode = .shaded
                packet.scene.instances[0].transform.columns.3.x = 0
                packet.scene.instances[0].material.alphaMode = .opaque
                packet.scene.instances[0].material.baseColorFactor.w = 1
                packet.jointPaletteMap.palettes[a] = JointPalette(matrices: [matrix_identity_float4x4,Self.translation(-1.4,0,0)])
            case 10: packet.renderSettings.enableShadows = false
            default: break
            }
            snapshots.append(try compare(packet,renderer: renderer,reference: reference,label: "skin-\(frame)"))
            XCTAssertEqual(renderer.lastFrameStats.meshBatchCount,3)
            XCTAssertEqual(renderer.lastFrameStats.culledMeshInstanceCount,0)
            XCTAssertEqual(renderer.lastFrameStats.lodMeshInstanceCount,0)
        }
        XCTAssertGreaterThan(try GridImage.difference(snapshots[0],snapshots[1]).pixelsOverThree,100)
        XCTAssertEqual(snapshots[2],snapshots[3],"empty palette must reset to identity")
        XCTAssertEqual(snapshots[3],snapshots[4],"removed palette must reset to identity")
        XCTAssertEqual(snapshots[0],snapshots[5],"re-added palette must use new frame bindings")
        XCTAssertGreaterThan(try GridImage.difference(snapshots[9],snapshots[10]).pixelsOverThree,20,"posed casters must change receiver pixels")
    }

    private func deformation(_ api: GraphicsAPI) throws {
        AssetRegistry.shared.registerForTesting(Self.quad(), at: 2)
        defer { AssetRegistry.shared.unregisterTestingMesh(at: 2) }
        let device = try Self.device(api), renderer = try NativeRenderer(device: device)
        let reference = try WGPUSceneReference(validation: true)
        let entity = EntityID(rawValue: 71)
        var packet = Self.packet()
        packet.scene.instances = [Self.pane(z: 0,color: SIMD4(0.7,0.6,0.2,1),entity: entity,scale: 1)]
        packet.scene.instances[0].transform = matrix_identity_float4x4
        var mesh = RenderDeformableMesh(entity: entity,revision: 1,
            positions: [SIMD3(-1,-1,0),SIMD3(1,-1,0),SIMD3(1,1,0),SIMD3(-1,1,0)],triangleIndices: [0,1,2,0,2,3])
        var snapshots: [Data] = []
        for frame in 0..<9 {
            packet.frameIndex = frame
            switch frame {
            case 2: mesh.revision = 2; mesh.positions[0].y = 0.5
            case 3: mesh.triangleIndices = [0,2,3]; mesh.topologyRevision &+= 1
            case 4:
                mesh.revision = 3; mesh.topologyRevision &+= 1
                mesh.positions.append(SIMD3(0,1.5,0)); mesh.normals.append(SIMD3(0,0,1)); mesh.textureCoordinates.append(.zero)
                mesh.triangleIndices = [0,1,2,0,2,3,3,2,4]
            case 5:
                mesh.revision = 4; mesh.positions[1].x = 0.3
                packet.scene.deformableMeshes = [mesh]
                packet.scene.instances.append(RenderInstance(meshIndex: 999,transform: matrix_identity_float4x4))
                XCTAssertThrowsError(try renderer.renderChecked(packet: packet))
                packet.scene.instances.removeLast()
            case 7: packet.renderSettings.stage = .r4LightingPBRShadow
            default: break
            }
            packet.scene.deformableMeshes = frame == 6 ? [] : [mesh]
            if frame == 8 {
                var invalid = mesh; invalid.triangleIndices = [99,1,2]
                packet.scene.deformableMeshes = [invalid,mesh,mesh]
            }
            snapshots.append(try compare(packet,renderer: renderer,reference: reference,label: "deform-\(frame)"))
            let expected: [UInt64] = [408,0,384,12,516,480,0,516,0]
            XCTAssertEqual(renderer.lastFrameStats.deformableUploadedBytes,expected[frame],"frame \(frame)")
            XCTAssertEqual(renderer.lastFrameStats.deformableMeshCount,frame == 6 ? 0 : 1)
            XCTAssertEqual(renderer.lastFrameStats.deformableRejectedMeshCount,frame == 8 ? 2 : 0)
        }
        XCTAssertEqual(snapshots[0],snapshots[1])
        XCTAssertGreaterThan(try GridImage.difference(snapshots[1],snapshots[2]).pixelsOverThree,100)
    }

    private func compare(_ packet: RenderPacket, renderer: NativeRenderer, reference: WGPUSceneReference, label: String) throws -> Data {
        try renderer.renderChecked(packet: packet); _ = try reference.render(packet: packet)
        let native = try GridImage.readback(device: renderer.device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
        let expected = try reference.readback(), delta = try GridImage.difference(native,expected)
        XCTAssertLessThan(delta.meanAbsoluteChannelError,0.5,"\(label): \(delta)")
        XCTAssertLessThan(delta.pixelsOverThree,max(1,delta.pixelCount/100),"\(label): \(delta)")
        let directory = URL(fileURLWithPath: "/tmp/guava-native-animation")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        try GridImage.writePPM(native,size: packet.drawableSize,to: directory.appendingPathComponent("\(label).ppm"))
        try GridImage.writePPM(expected,size: packet.drawableSize,to: directory.appendingPathComponent("wgpu-\(label).ppm"))
        return native
    }
    private static func device(_ api: GraphicsAPI) throws -> Device {
        try Device.make(DeviceConfig(preferredBackends: [api],enableValidation: false,framesInFlight: 3))
    }
    private static func packet() -> RenderPacket {
        var packet = MeshProbeScene.packet(size: .init(width: 192,height: 192))
        packet.scene.camera = RenderCamera(eye: SIMD3(0,0,8),target: .zero,near: 0.1,far: 100)
        packet.scene.camera.projection = .orthographic; packet.scene.camera.orthographicHeight = 8
        packet.renderSettings.shadowSettings = RenderShadowSettings(enabled: true,mapResolution: 128)
        packet.scene.lights = [RenderLight(type: .directional,direction: SIMD3(-0.4,-0.6,-1),intensity: 3,castShadows: true)]
        packet.scene.environment.ambientIntensity = 0.2
        return packet
    }
    private static func quad(joint: Float = 0) -> MeshAsset {
        var vertices: [Float] = []
        for p: SIMD3<Float> in [SIMD3(-1,-1,0),SIMD3(1,-1,0),SIMD3(1,1,0),SIMD3(-1,1,0)] {
            MeshAsset.appendVertex(to: &vertices,position: p,normal: SIMD3(0,0,1),
                joints: SIMD4(0,joint,0,0),weights: joint == 0 ? SIMD4(1,0,0,0) : SIMD4(0.25,0.75,0,0))
        }
        return MeshAsset(name: "native-animated-quad",vertices: vertices,indices: [0,1,2,0,2,3])
    }
    private static func pane(z: Float, color: SIMD4<Float>, blend: Bool = false, x: Float = 0,
                             entity: EntityID? = nil, scale: Float = 8) -> RenderInstance {
        var transform = translation(x,0,z); transform.columns.0.x = scale; transform.columns.1.y = 2
        return RenderInstance(meshIndex: 2,transform: transform,
            material: RenderMaterial(baseColorFactor: color,alphaMode: blend ? .blend : .opaque,doubleSided: true),entity: entity)
    }
    private static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var result = matrix_identity_float4x4; result.columns.3 = SIMD4(x,y,z,1); return result
    }
}
