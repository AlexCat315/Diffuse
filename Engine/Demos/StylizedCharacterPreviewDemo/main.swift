import Foundation
import RenderBackend
import RHIWGPU
import SceneRuntime
import SIMDCompat

enum CharacterPreviewState: String, CaseIterable {
    case idle
    case attack
    case hit
    case death
}

struct PreviewConfig {
    var framesPerState: Int = 18
    var drawableSize = RenderDrawableSize(width: 1280, height: 720)
}

func parseConfig(arguments: [String]) -> PreviewConfig {
    var config = PreviewConfig()
    if let index = arguments.firstIndex(of: "--frames"),
       arguments.indices.contains(index + 1),
       let frames = Int(arguments[index + 1]) {
        config.framesPerState = max(1, frames)
    }
    return config
}

func translation(_ value: SIMD3<Float>) -> simd_float4x4 {
    var matrix = matrix_identity_float4x4
    matrix.columns.3 = SIMD4<Float>(value, 1)
    return matrix
}

func scale(_ value: SIMD3<Float>) -> simd_float4x4 {
    var matrix = matrix_identity_float4x4
    matrix.columns.0.x = value.x
    matrix.columns.1.y = value.y
    matrix.columns.2.z = value.z
    return matrix
}

func rotationY(_ radians: Float) -> simd_float4x4 {
    let c = cos(radians)
    let s = sin(radians)
    return simd_float4x4(
        SIMD4<Float>( c, 0, -s, 0),
        SIMD4<Float>( 0, 1,  0, 0),
        SIMD4<Float>( s, 0,  c, 0),
        SIMD4<Float>( 0, 0,  0, 1)
    )
}

func rotationZ(_ radians: Float) -> simd_float4x4 {
    let c = cos(radians)
    let s = sin(radians)
    return simd_float4x4(
        SIMD4<Float>( c, s, 0, 0),
        SIMD4<Float>(-s, c, 0, 0),
        SIMD4<Float>( 0, 0, 1, 0),
        SIMD4<Float>( 0, 0, 0, 1)
    )
}

func characterTransform(state: CharacterPreviewState, phase: Float) -> simd_float4x4 {
    switch state {
    case .idle:
        let bob = sin(phase * .pi * 2.0) * 0.08
        return translation(SIMD3<Float>(0, bob, 0)) * rotationY(sin(phase * .pi * 2.0) * 0.08)
    case .attack:
        let lunge = sin(min(phase, 0.55) / 0.55 * .pi) * 0.85
        return translation(SIMD3<Float>(lunge, 0, -0.15)) * rotationZ(-0.28) * scale(SIMD3<Float>(1.06, 0.96, 1.0))
    case .hit:
        let recoil = sin(phase * .pi) * -0.55
        return translation(SIMD3<Float>(recoil, 0.05, 0)) * rotationZ(0.18) * scale(SIMD3<Float>(0.96, 1.04, 1.0))
    case .death:
        let fall = min(phase * 1.15, 1.0)
        return translation(SIMD3<Float>(-0.25 * fall, -0.7 * fall, 0)) * rotationZ(-1.15 * fall) * scale(SIMD3<Float>(1.0, 1.0 - 0.32 * fall, 1.0))
    }
}

func makeScene(state: CharacterPreviewState, phase: Float) -> RenderScene {
    let camera = RenderCamera(
        eye: SIMD3<Float>(0, 2.3, 7.0),
        target: SIMD3<Float>(0, 0.6, 0),
        up: SIMD3<Float>(0, 1, 0),
        fovYRadians: .pi / 4.5,
        near: 0.1,
        far: 50.0
    )
    return RenderScene(
        camera: camera,
        instances: [
            RenderInstance(meshIndex: 1, transform: characterTransform(state: state, phase: phase))
        ]
    )
}

let config = parseConfig(arguments: CommandLine.arguments)
let backend = WGPUBackend(config: WGPUDeviceConfig(validationEnabled: false))
try backend.initialize()
defer { try? backend.shutdown() }

let renderer = WGPURenderer(backend: backend, renderSurface: nil)
renderer.initialize()

let settings = RenderSettings(
    stage: .r5PostProcess,
    enableBloom: false,
    enableOffscreenViewport: true,
    enableStylizedCharacterShading: true,
    stylizedCharacterStyle: .colorfulInkCard
)

var frameIndex = 0
for state in CharacterPreviewState.allCases {
    for localFrame in 0..<config.framesPerState {
        let phase = Float(localFrame) / Float(max(config.framesPerState - 1, 1))
        let packet = RenderPacket(
            frameIndex: frameIndex,
            deltaTime: 1.0 / 60.0,
            drawableSize: config.drawableSize,
            scene: makeScene(state: state, phase: phase),
            sceneSnapshot: SceneRuntimeSnapshot(entityCount: 1, revision: UInt64(frameIndex)),
            renderSettings: settings,
            simulationTimeSeconds: Double(frameIndex) / 60.0
        )
        renderer.render(packet: packet)
        frameIndex += 1
    }
    let stats = renderer.currentFrameStats()
    print("[stylized-character-preview] state=\(state.rawValue) frames=\(config.framesPerState) passes=\(stats.activePasses.map(\.rawValue).joined(separator: ",")) drawCalls=\(stats.drawCallCount)")
}
