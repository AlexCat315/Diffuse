// NativeRHI Vulkan — runtime loader and backend entry point.
//
// The Vulkan loader (libvulkan) is vendored in `VulkanLoader.xcframework` and
// linked at build time, exactly like the other native dependencies. We bind the
// linked `vkGetInstanceProcAddr` and build the full command table lazily. The
// driver (an ICD such as MoltenVK) is still discovered by the loader at
// runtime; if no physical device is enumerated, `isAvailable` is false and
// `make` throws a clear `RHIError.unsupportedBackend` instead of crashing.

#if canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation
import Darwin

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
        guard let sym = dlsym(Self.rtldDefault, "vkGetInstanceProcAddr") else { return nil }
        let gipa = unsafeBitCast(OpaquePointer(sym), to: GIPASelf.self)
        return VulkanLoader(getInstanceProcAddr: gipa)
    }

    /// Darwin's `RTLD_DEFAULT` (a macro that Swift does not import): search
    /// every image in the process, including the linked libvulkan dylib.
    private static var rtldDefault: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: -2)
    }

    /// Resolves an entry point through `vkGetInstanceProcAddr`.
    func resolve(instance: VkInstance?, name: String) -> UnsafeRawPointer? {
        name.withCString { cName in
            guard let fn = getInstanceProcAddr(instance, cName) else { return nil }
            return UnsafeRawPointer(fn)
        }
    }

    /// Resolves a global-level symbol from the linked image. The loader exports
    /// the global commands (vkCreateInstance, vkEnumeratePhysicalDevices, …),
    /// and some loaders do not return them through GIPA(NULL, ...).
    func resolveGlobal(name: String) -> UnsafeRawPointer? {
        name.withCString { cName in
            guard let sym = dlsym(Self.rtldDefault, cName) else { return nil }
            return UnsafeRawPointer(sym)
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
        guard let createPtr = loader.resolve(instance: nil, name: "vkCreateInstance"),
              let enumPtr = loader.resolveGlobal(name: "vkEnumeratePhysicalDevices") else {
            return false
        }
        let createFn = unsafeBitCast(OpaquePointer(createPtr), to: PFN_vkCreateInstance.self)
        let enumFn = unsafeBitCast(OpaquePointer(enumPtr), to: PFN_vkEnumeratePhysicalDevices.self)

        var appInfo = VkApplicationInfo()
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        appInfo.apiVersion = (1 << 22) | (1 << 12)
        var extNames: [UnsafePointer<CChar>?] = []
        #if os(macOS)
        extNames.append(vkExtName("VK_KHR_portability_enumeration"))
        #endif
        var info = VkInstanceCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
        withUnsafePointer(to: &appInfo) { info.pApplicationInfo = $0 }
        info.enabledExtensionCount = UInt32(extNames.count)
        extNames.withUnsafeBufferPointer { info.ppEnabledExtensionNames = $0.baseAddress }
        #if os(macOS)
        info.flags = UInt32(VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR.rawValue)
        #endif

        guard let instance = vkWithOutHandle({ createFn(&info, nil, $0) }),
              instance != vkNull() else { return false }
        var count: UInt32 = 0
        let rc = enumFn(instance, &count, nil)
        if let destroyPtr = loader.resolve(instance: instance, name: "vkDestroyInstance") {
            let destroyFn = unsafeBitCast(OpaquePointer(destroyPtr), to: PFN_vkDestroyInstance.self)
            destroyFn(instance, nil)
        }
        return rc == VK_SUCCESS && count > 0
    }
}

#endif // canImport(CVulkanHeaders)
