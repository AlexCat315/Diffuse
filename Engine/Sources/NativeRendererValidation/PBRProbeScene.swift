import RenderBackend
import SceneRuntime
import SIMDCompat

public enum PBRProbeScene {
    /// Same real geometry as the mesh probe, with a receiver and two shadowed
    /// directional lights. The primary light uses two of the four atlas tiles.
    public static func packet(size: RenderDrawableSize, frame: Int = 0) -> RenderPacket {
        var packet = MeshProbeScene.packet(size: size, frame: frame)
        packet.renderSettings.stage = .r4LightingPBRShadow
        packet.renderSettings.debugViewMode = .shaded
        packet.renderSettings.enableEditorGrid = true
        packet.renderSettings.shadowSettings = RenderShadowSettings(enabled: true, mapResolution: 256,
            depthBias: 0.004, strength: 0.85, maxShadowedDirectionalLights: 2, directionalCascadeCount: 2)
        packet.scene.environment = RenderEnvironment(ambientColor: SIMD3(0.8,0.9,1), ambientIntensity: 0.2, exposure: 1.2)
        packet.scene.lights = [
            RenderLight(type: .directional, direction: SIMD3(-0.6,-1,-0.4), color: SIMD3(1,0.8,0.65), intensity: 3, castShadows: true),
            RenderLight(type: .directional, direction: SIMD3(0.4,-0.6,0.8), color: SIMD3(0.35,0.55,1), intensity: 1, castShadows: true),
            RenderLight(type: .point, position: SIMD3(0,3,2), color: SIMD3(1,0.25,0.2), intensity: 5, range: 12)
        ]
        var ground = matrix_identity_float4x4
        ground.columns.0.x = 12; ground.columns.1.y = 0.2; ground.columns.2.z = 12
        ground.columns.3.y = -0.3
        packet.scene.instances.append(RenderInstance(meshIndex: 0, transform: ground,
            material: RenderMaterial(baseColorFactor: SIMD4(0.5,0.5,0.55,1))))
        return packet
    }
}
