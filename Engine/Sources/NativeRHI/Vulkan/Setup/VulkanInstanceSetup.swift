#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import CVulkanHeaders

/// Global commands are resolved before creation; instance commands are resolved
/// only against the resulting instance and its enabled extensions.
enum VulkanInstanceSetup {
    static func create(loader: VulkanLoader, enableValidation: Bool, presentation: Bool = true) throws -> VkInstance {
        guard let createPtr = loader.resolve(instance: nil, name: "vkCreateInstance"),
              let enumeratePtr = loader.resolve(instance: nil, name: "vkEnumerateInstanceExtensionProperties") else {
            throw RHIError.unsupportedBackend("Vulkan loader is missing global entry points")
        }
        let create = unsafeBitCast(OpaquePointer(createPtr), to: CVulkanHeaders.PFN_vkCreateInstance.self)
        let enumerate = unsafeBitCast(OpaquePointer(enumeratePtr), to: CVulkanHeaders.PFN_vkEnumerateInstanceExtensionProperties.self)
        let supported = try extensions(enumerate)
        var names: [String] = []
        if presentation {
            guard supported.contains("VK_KHR_surface") else {
                throw RHIError.unsupportedBackend("Vulkan loader does not support VK_KHR_surface")
            }
            names.append("VK_KHR_surface")
            #if os(Windows)
            guard supported.contains("VK_KHR_win32_surface") else {
                throw RHIError.unsupportedBackend("Vulkan loader does not support Win32 presentation")
            }
            names.append("VK_KHR_win32_surface")
            #else
            // Either WSI extension may be absent on a Linux installation.
            names += ["VK_KHR_xlib_surface", "VK_KHR_wayland_surface"].filter { supported.contains($0) }
            #endif
        }
        let arena = VulkanScratch()
        var app = VkApplicationInfo(); app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        app.apiVersion = (1 << 22) | (3 << 12)
        var info = VkInstanceCreateInfo(); info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
        info.pApplicationInfo = UnsafePointer(arena.make(app))
        info.enabledExtensionCount = UInt32(names.count)
        info.ppEnabledExtensionNames = arena.store(names.map { Optional(arena.string($0)) })
        let layers = enableValidation ? ["VK_LAYER_KHRONOS_validation"] : []
        info.enabledLayerCount = UInt32(layers.count)
        info.ppEnabledLayerNames = arena.store(layers.map { Optional(arena.string($0)) })
        var instance: VkInstance?
        let result = withExtendedLifetime(arena) { create(&info, nil, &instance) }
        guard result == VK_SUCCESS, let instance else {
            throw RHIError.unsupportedBackend("vkCreateInstance failed: \(result)")
        }
        return instance
    }

    private static func extensions(_ enumerate: CVulkanHeaders.PFN_vkEnumerateInstanceExtensionProperties) throws -> Set<String> {
        for _ in 0..<4 {
            var count: UInt32 = 0
            guard enumerate(nil, &count, nil) == VK_SUCCESS else {
                throw RHIError.unsupportedBackend("Vulkan instance extension enumeration failed")
            }
            var values = Array(repeating: VkExtensionProperties(), count: Int(count))
            let result = enumerate(nil, &count, &values)
            if result == VK_INCOMPLETE { continue }
            guard result == VK_SUCCESS else {
                throw RHIError.unsupportedBackend("Vulkan instance extension enumeration failed: \(result)")
            }
            return Set(values.prefix(Int(count)).map { value in
                var name = value.extensionName
                return withUnsafePointer(to: &name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(VK_MAX_EXTENSION_NAME_SIZE)) { vkCString($0) }
                }
            })
        }
        throw RHIError.unsupportedBackend("Vulkan instance extensions changed repeatedly during enumeration")
    }
}
#endif
