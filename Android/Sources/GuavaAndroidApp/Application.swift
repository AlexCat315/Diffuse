import Foundation
import NativeRHI
import GuavaUIRuntime

/// Activity-retained state. Surface loss only releases the swapchain.
final class AndroidApplication {
    let device: Device
    let renderer: NativeDrawListRenderer
    let scene: DemoScene
    let scale: Float

    init(scale: Float, checkpoint: String, launch: SceneLaunch) throws {
        self.scale = scale.isFinite ? min(4, max(1, scale)) : 1
        device = try Device.make(DeviceConfig(enableValidation: false))
        renderer = try NativeDrawListRenderer(device: device)
        try renderer.configure(format: .rgba8Unorm)
        scene = try DemoScene(checkpoint: checkpoint, launch: launch, scale: self.scale, device: device)
    }
}
