import RenderBackend
import SceneRuntime
import SIMDCompat

public enum PostProbeScene {
    /// Twelve-frame holds exercise SSR refinement, TAA convergence, and snapshot
    /// reuse, followed by camera motion which invalidates the cached image.
    public static func packet(size: RenderDrawableSize, frame: Int = 0) -> RenderPacket {
        var packet = PBRProbeScene.packet(size: size,frame: frame)
        packet.renderSettings.stage = .r5PostProcess
        packet.renderSettings.enableSSAO = true; packet.renderSettings.enableSSR = true
        packet.renderSettings.enableTAA = true; packet.renderSettings.enableBloom = true; packet.renderSettings.enableFXAA = true
        packet.scene.camera.eye.x += Float((frame/12)%11)*0.04
        packet.scene.lights[2].intensity = 40
        var transform = matrix_identity_float4x4; transform.columns.3 = SIMD4(0,1,3,1)
        packet.scene.instances.append(RenderInstance(meshIndex: 0,transform: transform,
            material: RenderMaterial(baseColorFactor: SIMD4(0.25,0.65,0.9,0.4),alphaMode: .blend,doubleSided: true)))
        return packet
    }
}
