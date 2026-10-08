import NativeRHI
import SIMDCompat

/// Validate supported scene features before allocating resources or acquiring a drawable.
enum NativePacketValidation {
    static func validate(_ packet: RenderPacket) throws -> RenderCameraMatrices {
        guard packet.drawableSize.width > 0, packet.drawableSize.height > 0,
              !packet.renderSettings.enableEditorGrid || packet.renderSettings.editorGridSpacing.isFinite else { throw RHIError.invalidArgument("native viewport must be nonempty") }
        guard [.r1MeshCamera,.r2MultiObjectDepth,.r3ViewportInterop,.r4LightingPBRShadow].contains(packet.renderSettings.stage),
              !packet.renderSettings.enableStylizedCharacterShading,
              !packet.renderSettings.enableSSAO, !packet.renderSettings.enableSSR,
              !packet.renderSettings.enableTAA, !packet.renderSettings.enableBloom, !packet.renderSettings.enableFXAA,
              packet.scene.particles.isEmpty, packet.scene.particleSimulationBatches.isEmpty,
              packet.inGameCanvas.commands.isEmpty else {
            throw RHIError.unsupportedFeature("native post effects, particles and UI migration is pending; use mesh rendering through r4")
        }
        let scene = packet.scene
        guard finite(scene.camera.eye), finite(scene.camera.target), finite(scene.camera.up),
              finite(scene.environment.ambientColor), scene.environment.ambientIntensity.isFinite,
              scene.environment.ambientIntensity >= 0, scene.environment.exposure.isFinite, scene.environment.exposure >= 0,
              scene.lights.allSatisfy({ finite($0.position) && finite($0.direction) && finite($0.color)
                && $0.intensity.isFinite && $0.intensity >= 0 && $0.range.isFinite && $0.range >= 0
                && $0.spotInnerAngleRadians.isFinite && $0.spotOuterAngleRadians.isFinite }),
              packet.renderSettings.shadowSettings.depthBias.isFinite,
              packet.renderSettings.shadowSettings.strength.isFinite,
              packet.renderSettings.shadowSettings.directionalCascadeSplitLambda.isFinite else {
            throw RHIError.invalidArgument("non-finite or negative native lighting input")
        }
        let matrices = RenderCameraMatrices.make(scene: packet.scene, drawableSize: packet.drawableSize)
        guard Self.finite(matrices.viewProjection), packet.scene.environment.exposure.isFinite,
              packet.scene.instances.allSatisfy({ Self.finite($0.transform) }) else {
            throw RHIError.invalidArgument("non-finite camera or instance transform")
        }
        for instance in packet.scene.instances {
            guard finite(instance.colorTint), instance.material.alphaCutoff?.isFinite != false,
                  instance.material.baseColorFactor.x.isFinite, instance.material.baseColorFactor.y.isFinite,
                  instance.material.baseColorFactor.z.isFinite, instance.material.baseColorFactor.w.isFinite else {
                throw RHIError.invalidArgument("non-finite material color")
            }
        }
        guard packet.jointPaletteMap.palettes.values.allSatisfy({ palette in
            palette.matrices.count <= Int(UInt32.max) && palette.matrices.allSatisfy(Self.finite)
        }) else { throw RHIError.invalidArgument("non-finite or oversized joint palette") }
        return matrices
    }
    private static func finite(_ matrix: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { column in (0..<4).allSatisfy { matrix[column][$0].isFinite } }
    }
    private static func finite(_ vector: SIMD3<Float>) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }
}
