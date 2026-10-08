// NativeRHI Vulkan — instance/physical/logical device creation and the real
// capability probe. Nothing here hardcodes ray tracing or mesh shaders: the
// reported capability set comes from the enumerated physical-device extensions
// and queried feature chain.

#if canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

/// Bundles the live Vulkan handles and resolved command tables the backend uses.
/// Kept small by grouping; the backend holds one of these plus its own state.
struct VulkanQueue {
    let handle: VkQueue
    let family: UInt32
}

struct VulkanQueues {
    let graphics: VulkanQueue
    let compute: VulkanQueue
    let transfer: VulkanQueue
}

struct VulkanContext {
    let instanceCommands: VulkanInstanceCommands
    let core: VulkanDeviceCoreCommands
    let resources: VulkanDeviceResourceCommands
    let draw: VulkanDeviceDrawCommands
    let sync: VulkanDeviceSyncCommands
    let auxiliary: VulkanAuxiliaryCommands
    let advanced: VulkanAdvancedCommands
    let rendering: VulkanRenderingCommands
    let limits: VkPhysicalDeviceLimits
    let features: VulkanFeatureSupport

    let instance: VkInstance
    let physicalDevice: VkPhysicalDevice
    let device: VkDevice

    let queues: VulkanQueues

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

        var complete = false
        var ownedDevice: VkDevice?
        defer {
            if !complete {
                if let ownedDevice { instanceCommands.destroyDevice(ownedDevice, nil) }
                destroyInstance(instanceCommands, instance: instance)
            }
        }
        guard let physicalDevice = try selectPhysicalDevice(instanceCommands, instance: instance) else {
            throw RHIError.unsupportedBackend("no Vulkan physical device (ICD) found")
        }

        var props = VkPhysicalDeviceProperties()
        instanceCommands.getPhysicalDeviceProperties(physicalDevice, &props)
        guard props.apiVersion >= ((1 << 22) | (3 << 12)) else {
            throw RHIError.unsupportedBackend("NativeRHI requires Vulkan 1.3")
        }
        let nameCapacity = MemoryLayout.size(ofValue: props.deviceName)
        let deviceName = withUnsafePointer(to: &props.deviceName) { namePtr in
            namePtr.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
                vkCString($0)
            }
        }

        let extensions = enumerateExtensions(instanceCommands, physicalDevice: physicalDevice)
        let families = findQueueFamilies(instanceCommands, physicalDevice: physicalDevice)

        guard families.graphics != UInt32.max else {
            throw RHIError.unsupportedBackend("no graphics-capable Vulkan queue family")
        }

        let queueFamilies = uniqueFamilies(families)
        let (createdDevice, features) = try createLogicalDevice(
            instanceCommands,
            physicalDevice: physicalDevice,
            families: families,
            uniqueFamilies: queueFamilies,
            extensions: extensions
        )
        guard let device = createdDevice else {
            throw RHIError.unsupportedBackend("vkCreateDevice failed")
        }

        ownedDevice = device
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

        complete = true
        return VulkanContext(
            instanceCommands: instanceCommands,
            core: core,
            resources: resources,
            draw: draw,
            sync: sync,
            auxiliary: VulkanAuxiliaryCommands(deviceResolver),
            advanced: VulkanAdvancedCommands(deviceResolver, features: features, commands: instanceCommands, physicalDevice: physicalDevice),
            rendering: VulkanRenderingCommands(deviceResolver),
            limits: props.limits,
            features: features,
            instance: instance,
            physicalDevice: physicalDevice,
            device: device,
            queues: VulkanQueues(
                graphics: VulkanQueue(handle: graphicsQueue, family: families.graphics),
                compute: VulkanQueue(handle: computeQueue, family: families.compute),
                transfer: VulkanQueue(handle: transferQueue, family: families.transfer)),
            deviceName: deviceName,
            extensions: extensions
        )
    }

    // MARK: Instance

    private static func createInstance(_ cmds: VulkanInstanceCommands,
                                       enableValidation: Bool) throws -> VkInstance? {
        let arena = VulkanScratch()
        var app = VkApplicationInfo()
        app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        app.apiVersion = (1 << 22) | (3 << 12)
        var names = ["VK_KHR_surface"]
        #if os(macOS)
        names += ["VK_KHR_portability_enumeration", "VK_EXT_metal_surface"]
        #elseif os(Windows)
        names += ["VK_KHR_win32_surface"]
        #elseif os(Linux)
        names += ["VK_KHR_xlib_surface"]
        #endif
        var info = VkInstanceCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
        info.pApplicationInfo = UnsafePointer(arena.make(app))
        info.enabledExtensionCount = UInt32(names.count)
        info.ppEnabledExtensionNames = arena.store(names.map { Optional(arena.string($0)) })
        let layers = enableValidation ? ["VK_LAYER_KHRONOS_validation"] : []
        info.enabledLayerCount = UInt32(layers.count)
        info.ppEnabledLayerNames = arena.store(layers.map { Optional(arena.string($0)) })
        #if os(macOS)
        info.flags = UInt32(VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR.rawValue)
        #endif
        return withExtendedLifetime(arena) { vkWithOutHandle { _ = cmds.createInstance(&info, nil, $0) } }
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

    private static func createLogicalDevice(
        _ cmds: VulkanInstanceCommands, physicalDevice: VkPhysicalDevice,
        families: QueueFamilies, uniqueFamilies: [UInt32], extensions: Set<String>
    ) throws -> (VkDevice?, VulkanFeatureSupport) {
        let arena = VulkanScratch()
        var mesh = VkPhysicalDeviceMeshShaderFeaturesEXT()
        mesh.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT
        let nativeMesh = arena.make(mesh)
        var query = VkPhysicalDeviceRayQueryFeaturesKHR()
        query.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR
        query.pNext = UnsafeMutableRawPointer(nativeMesh)
        let nativeQuery = arena.make(query)
        var structure = VkPhysicalDeviceAccelerationStructureFeaturesKHR()
        structure.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR
        structure.pNext = UnsafeMutableRawPointer(nativeQuery)
        let nativeStructure = arena.make(structure)
        var vk13 = VkPhysicalDeviceVulkan13Features()
        vk13.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
        vk13.pNext = UnsafeMutableRawPointer(nativeStructure)
        let native13 = arena.make(vk13)
        var vk12 = VkPhysicalDeviceVulkan12Features()
        vk12.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
        vk12.pNext = UnsafeMutableRawPointer(native13)
        let native12 = arena.make(vk12)
        var supported = VkPhysicalDeviceFeatures2()
        supported.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
        supported.pNext = UnsafeMutableRawPointer(native12)
        cmds.getPhysicalDeviceFeatures2(physicalDevice, &supported)
        guard native12.pointee.timelineSemaphore != 0, native13.pointee.dynamicRendering != 0 else {
            throw RHIError.unsupportedBackend("NativeRHI requires Vulkan 1.3 dynamic rendering and timeline semaphores")
        }
        var result = VulkanFeatureSupport()
        result.dynamicRendering = true
        result.nonSolidFill = supported.features.fillModeNonSolid != 0
        result.accelerationStructures = native12.pointee.bufferDeviceAddress != 0 && nativeStructure.pointee.accelerationStructure != 0
            && extensions.contains("VK_KHR_acceleration_structure") && extensions.contains("VK_KHR_deferred_host_operations")
        result.rayQuery = result.accelerationStructures && nativeQuery.pointee.rayQuery != 0 && extensions.contains("VK_KHR_ray_query")
        result.mesh = nativeMesh.pointee.meshShader != 0 && extensions.contains("VK_EXT_mesh_shader")
        result.task = result.mesh && nativeMesh.pointee.taskShader != 0
        let priority = arena.make(Float(1))
        let queues = uniqueFamilies.map { family in
            var info = VkDeviceQueueCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
            info.queueFamilyIndex = family
            info.queueCount = 1
            info.pQueuePriorities = UnsafePointer(priority)
            return info
        }
        var names: [String] = []
        if extensions.contains("VK_KHR_swapchain") { names.append("VK_KHR_swapchain") }
        if extensions.contains("VK_KHR_portability_subset") { names.append("VK_KHR_portability_subset") }
        if result.accelerationStructures { names += ["VK_KHR_acceleration_structure", "VK_KHR_deferred_host_operations"] }
        if result.rayQuery { names.append("VK_KHR_ray_query") }
        if result.mesh { names.append("VK_EXT_mesh_shader") }
        // Rebuild an enable chain from the small implemented feature set.
        mesh.meshShader = result.mesh ? VK_TRUE : VK_FALSE
        mesh.taskShader = result.task ? VK_TRUE : VK_FALSE
        mesh.pNext = nil
        nativeMesh.pointee = mesh
        query.rayQuery = result.rayQuery ? VK_TRUE : VK_FALSE
        query.pNext = result.mesh ? UnsafeMutableRawPointer(nativeMesh) : nil
        nativeQuery.pointee = query
        structure.accelerationStructure = result.accelerationStructures ? VK_TRUE : VK_FALSE
        structure.pNext = result.rayQuery ? UnsafeMutableRawPointer(nativeQuery) : query.pNext
        nativeStructure.pointee = structure
        vk13.pNext = result.accelerationStructures ? UnsafeMutableRawPointer(nativeStructure) : structure.pNext
        vk13.dynamicRendering = VK_TRUE
        native13.pointee = vk13
        vk12.timelineSemaphore = VK_TRUE
        vk12.bufferDeviceAddress = result.accelerationStructures ? VK_TRUE : VK_FALSE
        native12.pointee = vk12
        var enabled = VkPhysicalDeviceFeatures()
        enabled.fillModeNonSolid = supported.features.fillModeNonSolid
        var info = VkDeviceCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
        info.pNext = UnsafeRawPointer(native12)
        info.queueCreateInfoCount = UInt32(queues.count)
        info.pQueueCreateInfos = arena.store(queues)
        info.enabledExtensionCount = UInt32(names.count)
        info.ppEnabledExtensionNames = arena.store(names.map { Optional(arena.string($0)) })
        info.pEnabledFeatures = UnsafePointer(arena.make(enabled))
        let device: VkDevice? = withExtendedLifetime(arena) {
            vkWithOutHandle { _ = cmds.createDevice(physicalDevice, &info, nil, $0) }
        }
        return (device, result)
    }

}

#endif // canImport(CVulkanHeaders)
