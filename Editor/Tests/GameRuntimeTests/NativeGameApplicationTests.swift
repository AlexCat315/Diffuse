import EngineCore
import Foundation
import GameRuntime
import NativeRHI
import RenderBackend
import Testing

@Suite("Native game runtime", .serialized)
struct NativeGameApplicationTests {
    #if os(macOS)
    @Test("GameApplication drives a NativeRenderer viewport on Metal", .timeLimit(.minutes(1)))
    func nativeViewport() throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal],
                                                   enableValidation: true,
                                                   framesInFlight: 2))
        let app = try GameApplication(renderDevice: .native(device))
        app.bootstrap()
        defer { app.shutdown() }

        for _ in 0..<4 { app.tick(deltaTime: 1.0 / 60.0) }
        for _ in 0..<40 where !app.currentViewportSurfaceState().isValid {
            Thread.sleep(forTimeInterval: 0.25)
        }
        let surface = app.currentViewportSurfaceState()
        #expect(surface.isValid)
        if case .native = surface.image?.storage {
            // The scene worker and the UI compositor can now share this Device.
        } else {
            Issue.record("NativeRenderer did not publish a native viewport image")
        }
    }
    #endif
}
