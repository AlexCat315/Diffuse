// NativeRHI Vulkan — instance/physical/logical device creation and the real
// capability probe. Nothing here hardcodes ray tracing or mesh shaders: the
// reported capability set comes from the enumerated physical-device extensions
// and queried feature chain.

#if (os(Windows) || os(Linux) || os(Android)) && canImport(CVulkanHeaders)
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
        let instance = try VulkanInstanceSetup.create(loader: loader, enableValidation: enableValidation)
        let instanceCommands = VulkanInstanceCommands { loader.resolve(instance: instance, name: $0) }

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
        guard props.apiVersion >= ((1 << 22) | (1 << 12)) else {
            throw RHIError.unsupportedBackend("NativeRHI requires Vulkan 1.1")
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
            extensions: extensions, apiVersion: props.apiVersion
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
        families: QueueFamilies, uniqueFamilies: [UInt32], extensions: Set<String>, apiVersion: UInt32
    ) throws -> (VkDevice?, VulkanFeatureSupport) {
        let arena = VulkanScratch()
        let core12 = apiVersion >= ((1 << 22) | (2 << 12))
        let maintenance = apiVersion >= ((1 << 22) | (3 << 12)) || extensions.contains("VK_KHR_maintenance4")
        guard core12 || extensions.contains("VK_KHR_timeline_semaphore") else {
            throw RHIError.unsupportedBackend("NativeRHI requires timeline semaphores (Vulkan 1.2 or VK_KHR_timeline_semaphore)")
        }
        // Query only structures supported by this device. Vulkan 1.1 drivers
        // cannot consume the aggregate Vulkan 1.2/1.3 feature structures.
        var tail: UnsafeMutableRawPointer?
        func feature<Value>(_ value: Value) -> UnsafeMutablePointer<Value> {
            arena.make(value)
        }
        var mesh = VkPhysicalDeviceMeshShaderFeaturesEXT()
        mesh.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT
        let nativeMesh = feature(mesh)
        if extensions.contains("VK_EXT_mesh_shader") { nativeMesh.pointee.pNext = tail; tail = UnsafeMutableRawPointer(nativeMesh) }
        var query = VkPhysicalDeviceRayQueryFeaturesKHR()
        query.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR
        let nativeQuery = feature(query)
        if core12 && extensions.contains("VK_KHR_ray_query") { nativeQuery.pointee.pNext = tail; tail = UnsafeMutableRawPointer(nativeQuery) }
        var structure = VkPhysicalDeviceAccelerationStructureFeaturesKHR()
        structure.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR
        let nativeStructure = feature(structure)
        if core12 && extensions.contains("VK_KHR_acceleration_structure") { nativeStructure.pointee.pNext = tail; tail = UnsafeMutableRawPointer(nativeStructure) }
        var address = VkPhysicalDeviceBufferDeviceAddressFeatures()
        address.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES
        let nativeAddress = feature(address)
        if core12 { nativeAddress.pointee.pNext = tail; tail = UnsafeMutableRawPointer(nativeAddress) }
        var localSize = VkPhysicalDeviceMaintenance4Features()
        localSize.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_4_FEATURES
        let nativeLocalSize = feature(localSize)
        if maintenance { nativeLocalSize.pointee.pNext = tail; tail = UnsafeMutableRawPointer(nativeLocalSize) }
        var timeline = VkPhysicalDeviceTimelineSemaphoreFeatures()
        timeline.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES
        timeline.pNext = tail
        let nativeTimeline = feature(timeline)
        var drawParameters = VkPhysicalDeviceShaderDrawParametersFeatures()
        drawParameters.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_DRAW_PARAMETERS_FEATURES
        drawParameters.pNext = UnsafeMutableRawPointer(nativeTimeline)
        let nativeDraw = feature(drawParameters)
        var supported = VkPhysicalDeviceFeatures2()
        supported.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
        supported.pNext = UnsafeMutableRawPointer(nativeDraw)
        cmds.getPhysicalDeviceFeatures2(physicalDevice, &supported)
        guard nativeTimeline.pointee.timelineSemaphore != 0 else {
            throw RHIError.unsupportedBackend("Vulkan timeline semaphore feature is unavailable")
        }
        guard nativeDraw.pointee.shaderDrawParameters != 0, supported.features.drawIndirectFirstInstance != 0 else {
            throw RHIError.unsupportedBackend("NativeRHI requires shader draw parameters and indirect firstInstance")
        }
        var result = VulkanFeatureSupport()
        result.spirvVersion = apiVersion >= ((1 << 22) | (3 << 12)) ? 0x00010600
            : core12 ? 0x00010500 : extensions.contains("VK_KHR_spirv_1_4") ? 0x00010400 : 0x00010300
        result.maintenance4 = nativeLocalSize.pointee.maintenance4 != 0
        result.nonSolidFill = supported.features.fillModeNonSolid != 0
        result.accelerationStructures = core12 && nativeAddress.pointee.bufferDeviceAddress != 0 && nativeStructure.pointee.accelerationStructure != 0
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
        if !core12 {
            names.append("VK_KHR_timeline_semaphore")
            if extensions.contains("VK_KHR_spirv_1_4") {
                names += ["VK_KHR_spirv_1_4", "VK_KHR_shader_float_controls"]
            }
        }
        if result.maintenance4 && apiVersion < ((1 << 22) | (3 << 12)) { names.append("VK_KHR_maintenance4") }
        if extensions.contains("VK_KHR_swapchain") { names.append("VK_KHR_swapchain") }
        if extensions.contains("VK_KHR_portability_subset") { names.append("VK_KHR_portability_subset") }
        if result.accelerationStructures { names += ["VK_KHR_acceleration_structure", "VK_KHR_deferred_host_operations"] }
        if result.rayQuery { names.append("VK_KHR_ray_query") }
        if result.mesh { names.append("VK_EXT_mesh_shader") }
        // Clear queried optional bits before enabling the implemented subset.
        tail = nil
        mesh.meshShader = result.mesh ? VK_TRUE : VK_FALSE
        mesh.taskShader = result.task ? VK_TRUE : VK_FALSE
        mesh.pNext = tail
        nativeMesh.pointee = mesh
        if result.mesh { tail = UnsafeMutableRawPointer(nativeMesh) }
        query.rayQuery = result.rayQuery ? VK_TRUE : VK_FALSE
        query.pNext = tail
        nativeQuery.pointee = query
        if result.rayQuery { tail = UnsafeMutableRawPointer(nativeQuery) }
        structure.accelerationStructure = result.accelerationStructures ? VK_TRUE : VK_FALSE
        structure.pNext = tail
        nativeStructure.pointee = structure
        if result.accelerationStructures { tail = UnsafeMutableRawPointer(nativeStructure) }
        address.bufferDeviceAddress = result.accelerationStructures ? VK_TRUE : VK_FALSE
        address.pNext = tail
        nativeAddress.pointee = address
        if result.accelerationStructures { tail = UnsafeMutableRawPointer(nativeAddress) }
        localSize.maintenance4 = result.maintenance4 ? VK_TRUE : VK_FALSE
        localSize.pNext = tail
        nativeLocalSize.pointee = localSize
        if result.maintenance4 { tail = UnsafeMutableRawPointer(nativeLocalSize) }
        timeline.timelineSemaphore = VK_TRUE
        timeline.pNext = tail
        nativeTimeline.pointee = timeline
        drawParameters.shaderDrawParameters = VK_TRUE
        nativeDraw.pointee = drawParameters
        var enabled = VkPhysicalDeviceFeatures()
        enabled.fillModeNonSolid = supported.features.fillModeNonSolid
        enabled.drawIndirectFirstInstance = VK_TRUE
        var info = VkDeviceCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
        info.pNext = UnsafeRawPointer(nativeDraw)
        info.queueCreateInfoCount = UInt32(queues.count)
        info.pQueueCreateInfos = arena.store(queues)
        info.enabledExtensionCount = UInt32(names.count)
        info.ppEnabledExtensionNames = arena.store(names.map { Optional(arena.string($0)) })
        info.pEnabledFeatures = UnsafePointer(arena.make(enabled))
        var device: VkDevice = vkNull()
        let status = withExtendedLifetime(arena) { cmds.createDevice(physicalDevice, &info, nil, &device) }
        guard status == VK_SUCCESS else { throw RHIError.unsupportedBackend("vkCreateDevice failed: \(status)") }
        return (device, result)
    }
}
#endif
