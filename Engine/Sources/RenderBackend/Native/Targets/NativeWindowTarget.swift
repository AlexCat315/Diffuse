import NativeRHI

/// One renderer's window target; other windows keep independent swapchains.
final class NativeWindowTarget {
    private let device: Device
    private let surface: RenderSurfaceDescriptor
    private var resource: SwapchainResource?
    private var configuredSize: RenderDrawableSize?

    init(device: Device, surface: RenderSurfaceDescriptor) {
        self.device = device; self.surface = surface
    }

    func configure(size: RenderDrawableSize) throws {
        guard configuredSize != size else { return }
        let descriptor = NativeRenderTargets.surfaceDescriptor(surface: surface, size: size)
        if let resource { try device.configureSwapchain(resource.swapchain, descriptor: descriptor) }
        else { resource = try SwapchainResource(device: device, descriptor: descriptor) }
        configuredSize = size
    }

    func acquire() throws -> SwapchainImage {
        guard let resource else { throw RHIError.swapchainAcquireFailed("window target is not configured") }
        return try device.acquireSwapchainImage(resource.swapchain)
    }
}
