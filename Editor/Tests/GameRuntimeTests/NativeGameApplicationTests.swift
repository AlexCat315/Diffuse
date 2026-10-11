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
        let app = try GameApplication(renderDevice: device)
        let completed = DispatchSemaphore(value: 0)
        app.setViewportDrawableSize(.init(width: 128, height: 96))
        app.bootstrap()
        app.engine.setRenderCompletionHandler { _ in completed.signal() }
        defer { app.shutdown() }

        app.tick(deltaTime: 1.0 / 60.0)
        try #require(completed.wait(timeout: .now() + 45) == .success)
        let surface = app.currentViewportSurfaceState()
        #expect(surface.isValid)
        #expect(surface.region.size == app.viewportDrawableSize)
        let resource = try #require(surface.image?.resource)
        #expect(resource.device === device)
    }
    #endif
}
