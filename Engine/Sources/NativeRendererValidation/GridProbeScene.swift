import EngineKernel
import RenderBackend
import SceneRuntime

public enum GridProbeScene {
    public static func packet(size: RenderDrawableSize, frame: Int = 0,
                              camera: RenderCamera? = nil) -> RenderPacket {
        var settings = RenderSettings(stage: .r1MeshCamera)
        settings.enableEditorGrid = true; settings.editorGridSpacing = 0.5
        return RenderPacket(frameIndex: frame, deltaTime: 1.0 / 60, drawableSize: size,
            scene: RenderScene(camera: camera ?? RenderCamera(eye: SIMD3(7, 6, 9), target: .zero,
                near: 0.1, far: 100), instances: []),
            sceneSnapshot: SceneRuntimeSnapshot(entityCount: 0, revision: UInt64(max(frame, 0))),
            renderSettings: settings, simulationTimeSeconds: Double(frame) / 60)
    }
}
