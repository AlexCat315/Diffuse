import AssetPipeline
import Foundation
import EngineKernel
import RenderBackend
import SceneRuntime
import SIMDCompat

public enum MeshProbeScene {
    public static func importedFixture() throws -> MeshAsset {
        let bundle = PackageResourceBundle.required(named: "GuavaEngine_RenderBackend")
        guard let url = bundle.url(forResource: "NativeSceneFixture", withExtension: "gltf") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try GLTFImporter.load(path: url.path)
    }

    /// The bundled OBJ fixture, repeated cube instances and a mirrored transform
    /// exercise production mesh residency, indexed draws and material batches.
    public static func packet(size: RenderDrawableSize, frame: Int = 0) -> RenderPacket {
        var settings = RenderSettings(stage: .r3ViewportInterop, debugViewMode: .unlit)
        settings.enableEditorGrid = false; settings.enableOffscreenViewport = true
        settings.enableRenderBundles = false
        let colors: [SIMD4<Float>] = [SIMD4(0.75,0.25,0.15,1),SIMD4(0.2,0.7,0.35,1),SIMD4(0.2,0.4,0.8,1)]
        var instances: [RenderInstance] = []
        for index in 0..<36 {
            let column = index % 6, row = index / 6
            var transform = matrix_identity_float4x4
            transform.columns.0.x = index == 5 ? -0.6 : 0.6
            transform.columns.1.y = 0.6; transform.columns.2.z = 0.6
            transform.columns.3 = SIMD4(Float(column)*1.5-3.75,0.6,Float(row)*1.5-3.75,1)
            instances.append(RenderInstance(meshIndex: 0, transform: transform,
                material: RenderMaterial(baseColorFactor: colors[index % 3])))
        }
        var fixture = matrix_identity_float4x4; fixture.columns.3 = SIMD4(0,2.5,0,1)
        instances.append(RenderInstance(meshIndex: 1, transform: fixture,
            material: RenderMaterial(baseColorFactor: SIMD4(0.7,0.65,0.2,1), doubleSided: true)))
        return RenderPacket(frameIndex: frame, deltaTime: 1.0/60, drawableSize: size,
            scene: RenderScene(camera: RenderCamera(eye: SIMD3(10,9,13), target: SIMD3(0,0.8,0), near: 0.1, far: 100), instances: instances),
            sceneSnapshot: SceneRuntimeSnapshot(entityCount: instances.count, revision: UInt64(max(frame,0))),
            renderSettings: settings, simulationTimeSeconds: Double(frame)/60)
    }
}
