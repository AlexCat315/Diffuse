import SceneRuntime
import SIMDCompat

enum OpaqueSceneFingerprint {
    /// Content hash of everything that determines the opaque render — camera,
    /// instances, lights, environment, render settings and skinning poses — but
    /// NOT the transparent particles. Equal hashes on consecutive frames mean
    /// the lit-opaque image is identical and can be served from
    /// `opaqueSnapshotTarget` instead of re-rendering every opaque pass.
    ///
    /// Collections are folded with wrapping sums so the hash is independent of array /
    /// dictionary iteration order (extraction order is not guaranteed stable).
    /// `Hasher`'s per-process seed is constant within a run, which is all the
    /// frame-to-frame comparison needs.
    static func make(packet: RenderPacket, settingsGeneration: UInt64) -> Int {
        var hasher = Hasher()

        let camera = packet.scene.camera
        hasher.combine(camera.eye)
        hasher.combine(camera.target)
        hasher.combine(camera.up)
        hasher.combine(camera.fovYRadians)
        hasher.combine(camera.projection)
        hasher.combine(camera.orthographicHeight)
        hasher.combine(camera.near)
        hasher.combine(camera.far)
        hasher.combine(packet.drawableSize.width)
        hasher.combine(packet.drawableSize.height)

        // Render settings are summarised by a monotonic generation counter that
        // is bumped whenever the active settings change.
        hasher.combine(settingsGeneration)

        let environment = packet.scene.environment
        hasher.combine(environment.ambientColor)
        hasher.combine(environment.ambientIntensity)
        hasher.combine(environment.exposure)

        hasher.combine(packet.scene.instances.count)
        var instanceAccumulator = 0
        for instance in packet.scene.instances {
            instanceAccumulator &+= instanceHash(instance)
        }
        hasher.combine(instanceAccumulator)

        hasher.combine(packet.scene.deformableMeshes.count)
        var deformableAccumulator = 0
        for mesh in packet.scene.deformableMeshes {
            var sub = Hasher()
            sub.combine(mesh.entity)
            sub.combine(mesh.revision)
            sub.combine(mesh.topologyRevision)
            sub.combine(mesh.vertexCount)
            sub.combine(mesh.triangleCount)
            deformableAccumulator &+= sub.finalize()
        }
        hasher.combine(deformableAccumulator)

        hasher.combine(packet.scene.lights.count)
        var lightAccumulator = 0
        for light in packet.scene.lights {
            lightAccumulator &+= lightHash(light)
        }
        hasher.combine(lightAccumulator)

        hasher.combine(packet.jointPaletteMap.palettes.count)
        var jointAccumulator = 0
        for (entity, palette) in packet.jointPaletteMap.palettes {
            var sub = Hasher()
            sub.combine(entity)
            for matrix in palette.matrices { Self.combine(&sub, matrix) }
            jointAccumulator &+= sub.finalize()
        }
        hasher.combine(jointAccumulator)

        return hasher.finalize()
    }

    private static func instanceHash(_ instance: RenderInstance) -> Int {
        var hasher = Hasher()
        hasher.combine(instance.entity)
        hasher.combine(instance.mesh.meshIndex)
        hasher.combine(instance.mesh.assetID)
        hasher.combine(instance.mesh.levelsOfDetail)
        Self.combine(&hasher, instance.transform)
        hasher.combine(instance.colorTint)
        let material = instance.material
        hasher.combine(material.baseColorFactor)
        hasher.combine(material.baseColorTextureIndex)
        hasher.combine(material.normalTextureIndex)
        hasher.combine(material.metallicFactor)
        hasher.combine(material.roughnessFactor)
        hasher.combine(material.emissiveFactor)
        hasher.combine(material.alphaMode)
        hasher.combine(material.alphaCutoff)
        hasher.combine(material.doubleSided)
        return hasher.finalize()
    }

    private static func lightHash(_ light: RenderLight) -> Int {
        var hasher = Hasher()
        hasher.combine(light.type)
        hasher.combine(light.position)
        hasher.combine(light.direction)
        hasher.combine(light.color)
        hasher.combine(light.intensity)
        hasher.combine(light.range)
        hasher.combine(light.spotInnerAngleRadians)
        hasher.combine(light.spotOuterAngleRadians)
        hasher.combine(light.castShadows)
        hasher.combine(light.entity)
        return hasher.finalize()
    }

    private static func combine(_ hasher: inout Hasher, _ matrix: simd_float4x4) {
        hasher.combine(matrix.columns.0)
        hasher.combine(matrix.columns.1)
        hasher.combine(matrix.columns.2)
        hasher.combine(matrix.columns.3)
    }
}
