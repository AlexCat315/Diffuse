/// Owns one native window swapchain. Retain the platform window until this
/// resource has been released and its device has completed pending work.
public final class SwapchainResource {
    public let device: Device
    public let swapchain: Swapchain

    public init(device: Device, descriptor: SurfaceDescriptor) throws {
        self.device = device
        swapchain = try device.makeSwapchain(descriptor)
    }

    /// Waits for pending work and releases this window's native swapchain.
    /// Idempotent; call before destroying the platform window.
    public func close() throws {
        try device.withFrameSession { try device.closeSwapchain(swapchain) }
    }

    deinit { device.destroy(swapchain) }
}
