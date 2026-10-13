/// Kept independent of Vulkan handles so platform policy can be tested without
/// a native window or a Vulkan loader.
enum VulkanPresentationPolicy {
    static func choose(vsyncEnabled: Bool, supportedModes: [PresentationMode]) throws -> PresentationMode {
        let preference: [PresentationMode] = vsyncEnabled ? [.fifo] : [.immediate, .mailbox, .fifo]
        guard let selected = preference.first(where: supportedModes.contains) else {
            throw RHIError.unsupportedFeature("Vulkan surface has no supported presentation mode for the requested VSync policy")
        }
        return selected
    }
}
