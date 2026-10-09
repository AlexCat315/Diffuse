import AssetPipeline
import RenderBackend
import SceneRuntime
import SIMDCompat

/// The PBR probe plus independently animated cubes, sorted translucent objects,
/// and a cloth stream whose vertices change while its topology stays resident.
public enum AnimatedProbeScene {
    public static func skinnedFixture() -> MeshAsset {
        var mesh = BuiltinMesh.cube(color: SIMD3(repeating: 1))
        mesh.name = "animated-native-probe"
        for vertex in 0..<mesh.vertexCount {
            let offset = vertex * MeshAsset.vertexFloatCount
            mesh.vertices[offset + MeshAsset.jointsFloatOffset] = mesh.vertices[offset + 1] > 0 ? 1 : 0
            mesh.vertices[offset + MeshAsset.weightsFloatOffset] = 1
        }
        return mesh
    }
    public static func packet(size: RenderDrawableSize, frame: Int = 0) -> RenderPacket {
        var packet = PBRProbeScene.packet(size: size,frame: frame)
        packet.scene.camera.eye.x += Float(frame % 11)*0.002
        let time = Float(frame)*0.04
        for index in 0..<6 {
            let entity = EntityID(rawValue: UInt64(100 + index))
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4(Float(index)*1.4-3.5,2.5,1,1)
            var joint = matrix_identity_float4x4
            let angle = sin(time + Float(index))*0.3
            joint.columns.0 = SIMD4(cos(angle),sin(angle),0,0)
            joint.columns.1 = SIMD4(-sin(angle),cos(angle),0,0)
            packet.jointPaletteMap.palettes[entity] = JointPalette(matrices: [matrix_identity_float4x4,joint])
            packet.scene.instances.append(RenderInstance(meshIndex: 2,transform: transform,
                material: RenderMaterial(baseColorFactor: SIMD4(0.25,0.65,0.85,1)),entity: entity))
            transform.columns.3 = SIMD4(Float(index)*1.4-3.5,0.9,3,1)
            packet.scene.instances.append(RenderInstance(meshIndex: 0,transform: transform,
                material: RenderMaterial(baseColorFactor: SIMD4(0.7,0.2,0.45,0.35),alphaMode: .blend,doubleSided: true)))
        }
        let cloth = EntityID(rawValue: 200)
        var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
        for y in 0..<12 {
            for x in 0..<12 {
                let u = Float(x)/11, v = Float(y)/11
                positions.append(SIMD3(u*4-2,3.2+v*2,sin(u*5+time)*0.3-1))
                if x < 11 && y < 11 {
                    let i = UInt32(y*12+x); indices.append(contentsOf: [i,i+1,i+13,i,i+13,i+12])
                }
            }
        }
        packet.scene.deformableMeshes = [RenderDeformableMesh(entity: cloth,revision: UInt64(max(frame,0)),
            topologyRevision: 1,positions: positions,triangleIndices: indices)]
        packet.scene.instances.append(RenderInstance(meshIndex: 0,transform: matrix_identity_float4x4,
            material: RenderMaterial(baseColorFactor: SIMD4(0.85,0.55,0.2,1),doubleSided: true),entity: cloth))
        return packet
    }
}
