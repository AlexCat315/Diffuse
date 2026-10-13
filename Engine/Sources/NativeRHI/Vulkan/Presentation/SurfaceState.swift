/// Observed native surface properties, independent of the image orientation
/// deliberately selected by the renderer. Repeated advisory statuses alone
/// must not retire a still-usable swapchain.
struct VulkanSurfaceState: Equatable {
    let extent: SIMD2<UInt32>
    let transform: UInt32
}
