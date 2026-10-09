import SceneRuntime
import SIMDCompat

/// Shared GPU ABI for the WGSL and Slang grid passes. Matrices use column-major
/// storage, followed by four aligned float4 values (192 bytes in total).
public struct EditorGridUniforms {
    var inverseRelativeViewProjection: simd_float4x4
    var relativeViewProjection: simd_float4x4
    var cameraPosition: SIMD4<Float>
    var viewport: SIMD4<Float>
    var planeU: SIMD4<Float>
    var planeV: SIMD4<Float>

    public static func make(packet: RenderPacket) -> EditorGridUniforms {
        make(camera: packet.scene.camera,
             matrices: RenderCameraMatrices.make(scene: packet.scene, drawableSize: packet.drawableSize),
             size: packet.drawableSize, spacing: packet.renderSettings.editorGridSpacing)
    }

    static func make(camera: RenderCamera, matrices: RenderCameraMatrices,
                     size: RenderDrawableSize, spacing: Float) -> EditorGridUniforms {
        let plane = EditorGridPlane.make(camera: camera)
        // Unproject relative to the eye to preserve rays in distant scenes.
        var rotation = matrices.view
        rotation.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        let relative = matrices.projection * rotation
        return EditorGridUniforms(
            inverseRelativeViewProjection: simd_inverse(relative),
            relativeViewProjection: relative,
            cameraPosition: SIMD4<Float>(camera.eye, 1),
            viewport: SIMD4<Float>(Float(max(size.width, 1)), Float(max(size.height, 1)),
                                   max(0.001, spacing), 0),
            planeU: SIMD4<Float>(plane.u, plane.uAxis),
            planeV: SIMD4<Float>(plane.v, plane.vAxis))
    }
}
