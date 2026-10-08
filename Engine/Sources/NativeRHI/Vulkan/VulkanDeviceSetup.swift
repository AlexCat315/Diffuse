// NativeRHI Vulkan — instance/physical/logical device creation and the real
// capability probe. Nothing here hardcodes ray tracing or mesh shaders: the
// reported capability set comes from the enumerated physical-device extensions
// and queried feature chain.

#if canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

/// Bundles the live Vulkan handles and resolved command tables the backend uses.
/// Kept small by grouping; the backend holds one of these plus its own state.
struct VulkanContext {
    let instanceCommands: VulkanInstanceCommands
    let core: VulkanDeviceCoreCommands
    let resources: VulkanDeviceResourceCommands
    let draw: VulkanDeviceDrawCommands
    let sync: VulkanDeviceSyncCommands

    let instance: VkInstance
    let physicalDevice: VkPhysicalDevice
    let device: VkDevice

    let graphicsQueue: VkQueue
    let computeQueue: VkQueue
    let transferQueue: VkQueue
    let graphicsFamily: UInt32
    let computeFamily: UInt32
    let transferFamily: UInt32

    let deviceName: String
    let extensions: Set<String>
}

enum VulkanDeviceSetup {
    /// Builds a full Vulkan context, throwing a clear error if any stage fails.
    static func make(loader: VulkanLoader, enableValidation: Bool) throws -> VulkanContext {
        let instanceResolver: VulkanResolver = { name in
            // Some loaders (notably Homebrew's vulkan-loader) do not return global
            // or instance-level commands through vkGetInstanceProcAddr(NULL, ...);
            // fall back to direct dlsym, which exports every core symbol.
            loader.resolve(instance: nil, name: name) ?? loader.resolveGlobal(name: name)
        }
        let instanceCommands = VulkanInstanceCommands(instanceResolver)

        guard let instance = try createInstance(instanceCommands,
                                                enableValidation: enableValidation) else {
            throw RHIError.unsupportedBackend("vkCreateInstance returned no instance")
        }

        guard let physicalDevice = try selectPhysicalDevice(instanceCommands, instance: instance) else {
            destroyInstance(instanceCommands, instance: instance)
            throw RHIError.unsupportedBackend("no Vulkan physical device (ICD) found")
        }

        var props = VkPhysicalDeviceProperties()
        instanceCommands.getPhysicalDeviceProperties(physicalDevice, &props)
        let nameCapacity = MemoryLayout.size(ofValue: props.deviceName)
        let deviceName = withUnsafePointer(to: &props.deviceName) { namePtr in
            namePtr.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
                vkCString($0)
            }
        }

        let extensions = enumerateExtensions(instanceCommands, physicalDevice: physicalDevice)
        let families = findQueueFamilies(instanceCommands, physicalDevice: physicalDevice)

        guard families.graphics != UInt32.max else {
            destroyInstance(instanceCommands, instance: instance)
            throw RHIError.unsupportedBackend("no graphics-capable Vulkan queue family")
        }

        let queueFamilies = uniqueFamilies(families)
        guard let device = try createLogicalDevice(
            instanceCommands,
            physicalDevice: physicalDevice,
            families: families,
            uniqueFamilies: queueFamilies,
            extensions: extensions
        ) else {
            destroyInstance(instanceCommands, instance: instance)
            throw RHIError.unsupportedBackend("vkCreateDevice failed")
        }

        let getDeviceQueue = instanceCommands.getDeviceQueue
        let graphicsQueue = vkWithOutHandle { getDeviceQueue(device, families.graphics, 0, $0) } ?? vkNull()
        let computeQueue = vkWithOutHandle { getDeviceQueue(device, families.compute, 0, $0) } ?? graphicsQueue
        let transferQueue = vkWithOutHandle { getDeviceQueue(device, families.transfer, 0, $0) } ?? graphicsQueue

        // Device-level entry points are resolved through vkGetDeviceProcAddr.
        guard let gdpaSym = loader.resolve(instance: instance, name: "vkGetDeviceProcAddr") else {
            throw RHIError.unsupportedBackend("vkGetDeviceProcAddr unavailable")
        }
        typealias GDPA = @convention(c) (VkDevice, UnsafePointer<CChar>?) -> OpaquePointer?
        let gdpa = unsafeBitCast(OpaquePointer(gdpaSym), to: GDPA.self)
        let deviceResolver: VulkanResolver = { name in
            name.withCString { cName in
                guard let fn = gdpa(device, cName) else { return nil }
                return UnsafeRawPointer(fn)
            }
        }

        let core = VulkanDeviceCoreCommands(deviceResolver)
        let resources = VulkanDeviceResourceCommands(deviceResolver)
        let draw = VulkanDeviceDrawCommands(deviceResolver)
        let sync = VulkanDeviceSyncCommands(deviceResolver)

        return VulkanContext(
            instanceCommands: instanceCommands,
            core: core,
            resources: resources,
            draw: draw,
            sync: sync,
            instance: instance,
            physicalDevice: physicalDevice,
            device: device,
            graphicsQueue: graphicsQueue,
            computeQueue: computeQueue,
            transferQueue: transferQueue,
            graphicsFamily: families.graphics,
            computeFamily: families.compute,
            transferFamily: families.transfer,
            deviceName: deviceName,
            extensions: extensions
        )
    }

    // MARK: Instance

    private static func createInstance(_ cmds: VulkanInstanceCommands,
                                       enableValidation: Bool) throws -> VkInstance? {
        var appInfo = VkApplicationInfo()
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        appInfo.apiVersion = (1 << 22) | (1 << 12)

        var extNames: [UnsafePointer<CChar>?] = []
        #if os(macOS)
        extNames.append(vkExtName("VK_KHR_portability_enumeration"))
        extNames.append(vkExtName("VK_EXT_metal_surface"))
        #endif

        var layers: [UnsafePointer<CChar>?] = []
        if enableValidation {
            layers.append(vkExtName("VK_LAYER_KHRONOS_validation"))
        }

        var info = VkInstanceCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
        withUnsafePointer(to: &appInfo) { info.pApplicationInfo = $0 }
        info.enabledExtensionCount = UInt32(extNames.count)
        extNames.withUnsafeBufferPointer { info.ppEnabledExtensionNames = $0.baseAddress }
        info.enabledLayerCount = UInt32(layers.count)
        layers.withUnsafeBufferPointer { info.ppEnabledLayerNames = $0.baseAddress }
        #if os(macOS)
        info.flags = UInt32(VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR.rawValue)
        #endif

        let instance = vkWithOutHandle { cmds.createInstance(&info, nil, $0) }
        return instance
    }

    private static func destroyInstance(_ cmds: VulkanInstanceCommands, instance: VkInstance) {
        cmds.destroyInstance(instance, nil)
    }

    // MARK: Physical device

    private static func selectPhysicalDevice(_ cmds: VulkanInstanceCommands,
                                             instance: VkInstance) throws -> VkPhysicalDevice? {
        var count: UInt32 = 0
        guard cmds.enumeratePhysicalDevices(instance, &count, nil) == VK_SUCCESS, count > 0 else {
            return nil
        }
        var devices: [VkPhysicalDevice] = Array(repeating: vkNull(), count: Int(count))
        guard cmds.enumeratePhysicalDevices(instance, &count, &devices) == VK_SUCCESS else {
            return nil
        }
        // Prefer a discrete GPU, then integrated; otherwise take the first.
        var chosen: VkPhysicalDevice?
        for device in devices {
            var props = VkPhysicalDeviceProperties()
            cmds.getPhysicalDeviceProperties(device, &props)
            if props.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU {
                chosen = device
                break
            }
            if props.deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU, chosen == nil {
                chosen = device
            }
        }
        return chosen ?? devices.first
    }

    private static func enumerateExtensions(_ cmds: VulkanInstanceCommands,
                                             physicalDevice: VkPhysicalDevice) -> Set<String> {
        var count: UInt32 = 0
        _ = cmds.enumerateDeviceExtensionProperties(physicalDevice, nil, &count, nil)
        guard count > 0 else { return [] }
        var props: [VkExtensionProperties] = Array(repeating: VkExtensionProperties(), count: Int(count))
        guard cmds.enumerateDeviceExtensionProperties(physicalDevice, nil, &count, &props) == VK_SUCCESS else {
            return []
        }
        var result = Set<String>()
        for index in 0..<Int(count) {
            var ext = props[index]
            let name = withUnsafePointer(to: &ext.extensionName) { namePtr in
                namePtr.withMemoryRebound(to: CChar.self, capacity: Int(VK_MAX_EXTENSION_NAME_SIZE)) {
                    vkCString($0)
                }
            }
            result.insert(name)
        }
        return result
    }

    private struct QueueFamilies {
        var graphics: UInt32 = .max
        var compute: UInt32 = .max
        var transfer: UInt32 = .max
    }

    private static func findQueueFamilies(_ cmds: VulkanInstanceCommands,
                                          physicalDevice: VkPhysicalDevice) -> QueueFamilies {
        var count: UInt32 = 0
        cmds.getPhysicalDeviceQueueFamilyProperties(physicalDevice, &count, nil)
        guard count > 0 else { return QueueFamilies() }
        var props: [VkQueueFamilyProperties] = Array(repeating: VkQueueFamilyProperties(), count: Int(count))
        cmds.getPhysicalDeviceQueueFamilyProperties(physicalDevice, &count, &props)

        var families = QueueFamilies()
        for index in 0..<Int(count) {
            var family = props[index]
            let flags = family.queueFlags
            if flags & UInt32(VK_QUEUE_GRAPHICS_BIT.rawValue) != 0, families.graphics == .max {
                families.graphics = UInt32(index)
            }
            if flags & UInt32(VK_QUEUE_COMPUTE_BIT.rawValue) != 0,
               flags & UInt32(VK_QUEUE_GRAPHICS_BIT.rawValue) == 0, families.compute == .max {
                families.compute = UInt32(index)
            }
            if flags & UInt32(VK_QUEUE_TRANSFER_BIT.rawValue) != 0,
               flags & UInt32(VK_QUEUE_GRAPHICS_BIT.rawValue) == 0, families.transfer == .max {
                families.transfer = UInt32(index)
            }
        }
        if families.compute == .max { families.compute = families.graphics }
        if families.transfer == .max { families.transfer = families.graphics }
        return families
    }

    private static func uniqueFamilies(_ families: QueueFamilies) -> [UInt32] {
        var seen = Set<UInt32>()
        var result: [UInt32] = []
        for family in [families.graphics, families.compute, families.transfer] {
            guard family != .max, !seen.contains(family) else { continue }
            seen.insert(family)
            result.append(family)
        }
        return result
    }

    private static func createLogicalDevice(_ cmds: VulkanInstanceCommands,
                                            physicalDevice: VkPhysicalDevice,
                                            families: QueueFamilies,
                                            uniqueFamilies: [UInt32],
                                            extensions: Set<String>) throws -> VkDevice? {
        var priorities: [Float] = uniqueFamilies.map { _ in 1.0 }
        var queueInfos: [VkDeviceQueueCreateInfo] = uniqueFamilies.map { family in
            var info = VkDeviceQueueCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
            info.queueFamilyIndex = family
            info.queueCount = 1
            info.pQueuePriorities = priorities.withUnsafeBufferPointer { $0.baseAddress }
            return info
        }

        var extNames: [UnsafePointer<CChar>?] = []
        if extensions.contains("VK_KHR_swapchain") {
            extNames.append(vkExtName("VK_KHR_swapchain"))
        }
        #if os(macOS)
        if extensions.contains("VK_KHR_portability_subset") {
            extNames.append(vkExtName("VK_KHR_portability_subset"))
        }
        #endif

        // Enable timeline semaphores (core in Vulkan 1.2+) explicitly via the
        // 1.2 feature chain so the planner's wait/signal values are honored.
        var vk12 = VkPhysicalDeviceVulkan12Features()
        vk12.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
        vk12.timelineSemaphore = VK_TRUE

        var features = VkPhysicalDeviceFeatures()
        features.samplerAnisotropy = VK_TRUE
        features.fillModeNonSolid = VK_TRUE

        var info = VkDeviceCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
        info.pNext = withUnsafeMutablePointer(to: &vk12) { UnsafeRawPointer($0) }
        info.queueCreateInfoCount = UInt32(queueInfos.count)
        queueInfos.withUnsafeMutableBufferPointer { buffer in
            info.pQueueCreateInfos = UnsafePointer(buffer.baseAddress)
        }
        info.enabledExtensionCount = UInt32(extNames.count)
        extNames.withUnsafeBufferPointer { info.ppEnabledExtensionNames = $0.baseAddress }
        info.pEnabledFeatures = withUnsafeMutablePointer(to: &features) { UnsafePointer($0) }

        return vkWithOutHandle { cmds.createDevice(physicalDevice, &info, nil, $0) }
    }
}

#endif // canImport(CVulkanHeaders)
