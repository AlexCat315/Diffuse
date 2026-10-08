// NativeRHI Vulkan — runtime loader and backend entry point.
//
// The native Windows/Linux Vulkan SDK provides the linked loader. Instance
// and device commands are resolved through their respective dispatch tables.
// A GPU driver is discovered by the loader at runtime. macOS uses Metal.

#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

/// Binds the linked loader's global `vkGetInstanceProcAddr` entry point.
final class VulkanLoader {
    private let getInstanceProcAddr: GIPASelf

    private init(getInstanceProcAddr: @escaping GIPASelf) {
        self.getInstanceProcAddr = getInstanceProcAddr
    }

    private typealias GIPASelf = @convention(c) (VkInstance?, UnsafePointer<CChar>?) -> OpaquePointer?

    /// The loader is linked into the process, so its symbols are found in the
    /// global image table. Returns nil only if the linked entry point is absent.
    static func open() -> VulkanLoader? {
        guard let sym = grhi_vulkan_get_instance_proc_addr() else { return nil }
        let gipa = unsafeBitCast(OpaquePointer(sym), to: GIPASelf.self)
        return VulkanLoader(getInstanceProcAddr: gipa)
    }

    /// Resolves an entry point through `vkGetInstanceProcAddr`.
    func resolve(instance: VkInstance?, name: String) -> UnsafeRawPointer? {
        name.withCString { cName in
            guard let fn = getInstanceProcAddr(instance, cName) else { return nil }
            return UnsafeRawPointer(fn)
        }
    }


}

/// Reports whether a usable Vulkan driver (ICD) is present. The loader itself
/// is always linked; "available" means at least one physical device is
/// enumerated. Result is cached because the instance probe is not free.
enum VulkanRuntime {
    private static let availability: Bool = probeAvailability()

    static var isAvailable: Bool { availability }

    static func make(config: DeviceConfig) throws -> RHIBackend {
        try VulkanBackend.make(config: config)
    }

    /// Creates a throwaway instance and confirms at least one physical device
    /// (ICD) is enumerated. Any failure means the platform has no usable
    /// Vulkan driver.
    private static func probeAvailability() -> Bool {
        guard let loader = VulkanLoader.open() else { return false }
        guard let instance = try? VulkanInstanceSetup.create(loader: loader, enableValidation: false, presentation: false),
              let destroyPtr = loader.resolve(instance: instance, name: "vkDestroyInstance") else { return false }
        let destroy = unsafeBitCast(OpaquePointer(destroyPtr), to: PFN_vkDestroyInstance.self)
        defer { destroy(instance, nil) }
        guard let enumPtr = loader.resolve(instance: instance, name: "vkEnumeratePhysicalDevices") else { return false }
        let enumerate = unsafeBitCast(OpaquePointer(enumPtr), to: PFN_vkEnumeratePhysicalDevices.self)
        var count: UInt32 = 0
        return enumerate(instance, &count, nil) == VK_SUCCESS && count > 0
    }
}

#endif
