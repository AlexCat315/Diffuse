import NativeRHI
import RenderBackend

struct GameContentSnapshot: Codable {
    let scripts: Int
    let entities: Int
    let rendered: Bool
    let surfaceID: UInt64
    let hud: [String]
    let player: [Float]?
}

/// Platform-internal integration seam; UI applications never depend on GameRuntime.
protocol GameContentSession: AnyObject {
    var surface: ViewportSurfaceState { get }
    func prepare(pixels: SIMD2<Int>, scale: Float, deltaTime: Double)
    func key(_ scancode: UInt32, down: Bool)
    func releaseKeys()
    func snapshot() -> GameContentSnapshot
}
