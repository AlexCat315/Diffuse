#if canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

struct VulkanAccelerationRecord {
    let native: VkAccelerationStructureKHR
    let result: Buffer
    let scratch: Buffer
    let instanceBuffer: Buffer?
    let scratchAddress: VkDeviceAddress
    let geometry: [VkAccelerationStructureGeometryKHR]
    let ranges: [VkAccelerationStructureBuildRangeInfoKHR]
    let topLevel: Bool
}

extension VulkanBackend {
    func bufferAddress(_ handle: Buffer) throws -> VkDeviceAddress {
        guard let record = registries.buffers[handle.id] else { throw RHIError.invalidArgument("unknown device-address buffer") }
        var info = VkBufferDeviceAddressInfo()
        info.sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO
        info.buffer = record.buffer
        let address = context.advanced.bufferAddress(context.device, &info)
        try rhiRequire(address != 0, "buffer device address unavailable")
        return address
    }
    func structureAddress(_ handle: AccelerationStructure) throws -> VkDeviceAddress {
        guard let record = registries.accelerationStructures[handle.id], let query = context.advanced.structureAddress else {
            throw RHIError.invalidArgument("unknown acceleration structure")
        }
        var info = VkAccelerationStructureDeviceAddressInfoKHR()
        info.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR
        info.accelerationStructure = record.native
        let address = query(context.device, &info)
        try rhiRequire(address != 0, "acceleration structure address unavailable")
        return address
    }
    private func accelerationBuffer(size: VkDeviceSize) throws -> Buffer {
        guard let bytes = Int(exactly: size), bytes > 0 else { throw RHIError.outOfMemory }
        let handle = Buffer(id: registries.nextInternalID())
        try createBuffer(handle, descriptor: BufferDescriptor(size: bytes, usage: [.storageRead, .storageWrite, .transferDestination]))
        return handle
    }
    func createAccelerationStructure(_ handle: AccelerationStructure, descriptor: AccelerationStructureDescriptor) throws {
        guard context.features.accelerationStructures, let sizes = context.advanced.buildSizes,
              let create = context.advanced.createStructure else { throw RHIError.unsupportedFeature("Vulkan acceleration structures unavailable") }
        var owned: [Buffer] = []
        var committed = false
        defer { if !committed { for buffer in owned { destroyBuffer(buffer) } } }
        var geometry: [VkAccelerationStructureGeometryKHR] = []
        var ranges: [VkAccelerationStructureBuildRangeInfoKHR] = []
        var instances: Buffer?
        let topLevel: Bool
        switch descriptor {
        case .bottomLevel(let triangles):
            topLevel = false
            for triangle in triangles {
                guard let vertices = registries.buffers[triangle.vertices.id] else { throw RHIError.invalidArgument("unknown BLAS vertices") }
                let count = try rhiCount(triangle.triangleCount)
                try rhiRequire(count > 0 && count <= UInt32.max / 3 && triangle.vertexStride >= 12, "invalid BLAS geometry")
                let (vertexBytes, overflow) = (Int(count) * 3 - 1).multipliedReportingOverflow(by: triangle.vertexStride)
                try rhiRequire(!overflow && vertexBytes <= Int.max - 12, "BLAS range overflow")
                try rhiByteRange(offset: triangle.vertexOffset, size: vertexBytes + 12, capacity: vertices.size)
                var native = VkAccelerationStructureGeometryKHR()
                native.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR
                native.geometryType = VK_GEOMETRY_TYPE_TRIANGLES_KHR
                native.flags = VK_GEOMETRY_OPAQUE_BIT_KHR.rawValue
                var data = VkAccelerationStructureGeometryTrianglesDataKHR()
                data.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR
                data.vertexFormat = VK_FORMAT_R32G32B32_SFLOAT
                data.vertexData.deviceAddress = try bufferAddress(triangle.vertices) + UInt64(triangle.vertexOffset)
                data.vertexStride = UInt64(triangle.vertexStride); data.maxVertex = count * 3 - 1
                data.indexType = VK_INDEX_TYPE_NONE_KHR
                native.geometry.triangles = data; geometry.append(native)
                ranges.append(VkAccelerationStructureBuildRangeInfoKHR(primitiveCount: count, primitiveOffset: 0, firstVertex: 0, transformOffset: 0))
            }
        case .topLevel(let authored):
            topLevel = true
            try rhiRequire(!authored.isEmpty && authored.count <= 0x100_0000, "invalid TLAS instance count")
            var bytes = Data(count: authored.count * 64)
            try bytes.withUnsafeMutableBytes { destination in
                for (index, instance) in authored.enumerated() {
                    guard let structure = registries.accelerationStructures[instance.structure.id], !structure.topLevel else {
                        throw RHIError.invalidArgument("TLAS must reference a BLAS")
                    }
                    try rhiRequire(instance.mask <= 0xff, "instance mask exceeds eight bits")
                    let transform = [instance.transform.x, instance.transform.y, instance.transform.z].flatMap { [$0.x, $0.y, $0.z, $0.w] }
                    let address = try structureAddress(instance.structure)
                    transform.withUnsafeBufferPointer { grhi_vulkan_pack_instance(destination.baseAddress!.advanced(by: index * 64), $0.baseAddress, UInt32(index), instance.mask, address) }
                }
            }
            // Coherent host storage makes instance data visible to whichever
            // queue submits the build; no hidden graphics-queue copy is needed.
            let buffer = Buffer(id: registries.nextInternalID())
            try createBuffer(buffer, descriptor: BufferDescriptor(size: bytes.count, usage: [.transferSource, .transferDestination]))
            owned.append(buffer); instances = buffer
            try uploadBufferData(buffer, offset: 0, data: bytes)
            var native = VkAccelerationStructureGeometryKHR()
            native.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR
            native.geometryType = VK_GEOMETRY_TYPE_INSTANCES_KHR
            native.geometry.instances.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR
            native.geometry.instances.data.deviceAddress = try bufferAddress(buffer)
            geometry.append(native)
            ranges.append(VkAccelerationStructureBuildRangeInfoKHR(primitiveCount: UInt32(authored.count), primitiveOffset: 0, firstVertex: 0, transformOffset: 0))
        }
        try rhiRequire(!geometry.isEmpty, "acceleration structure requires input")
        let arena = VulkanScratch()
        var input = VkAccelerationStructureBuildGeometryInfoKHR()
        input.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR
        input.type = topLevel ? VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR : VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR
        input.flags = VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR.rawValue
        input.mode = VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR
        input.geometryCount = UInt32(geometry.count); input.pGeometries = arena.store(geometry)
        var allocation = VkAccelerationStructureBuildSizesInfoKHR()
        allocation.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR
        withExtendedLifetime(arena) { sizes(context.device, VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR, &input, arena.store(ranges.map(\.primitiveCount)), &allocation) }
        let result = try accelerationBuffer(size: allocation.accelerationStructureSize); owned.append(result)
        let alignment = context.advanced.scratchAlignment
        let scratch = try accelerationBuffer(size: allocation.buildScratchSize + alignment); owned.append(scratch)
        let scratchBase = try bufferAddress(scratch)
        let scratchAddress = (scratchBase + alignment - 1) / alignment * alignment
        var info = VkAccelerationStructureCreateInfoKHR()
        info.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR
        info.buffer = registries.buffers[result.id]!.buffer; info.size = allocation.accelerationStructureSize; info.type = input.type
        var created: VkAccelerationStructureKHR?
        guard create(context.device, &info, nil, &created) == VK_SUCCESS, let native = created else { throw RHIError.outOfMemory }
        registries.accelerationStructures[handle.id] = VulkanAccelerationRecord(native: native, result: result, scratch: scratch, instanceBuffer: instances, scratchAddress: scratchAddress, geometry: geometry, ranges: ranges, topLevel: topLevel)
        committed = true
    }
    func destroyAccelerationStructure(_ handle: AccelerationStructure) {
        guard let record = registries.accelerationStructures.removeValue(forKey: handle.id) else { return }
        context.advanced.destroyStructure?(context.device, record.native, nil)
        destroyBuffer(record.result); destroyBuffer(record.scratch)
        if let buffer = record.instanceBuffer { destroyBuffer(buffer) }
    }
    func encodeAccelerationBuild(cmd: VkCommandBuffer, handle: AccelerationStructure) throws {
        guard let structure = registries.accelerationStructures[handle.id], let build = context.advanced.build else {
            throw RHIError.invalidArgument("unknown acceleration build")
        }
        memoryDependency(cmd: cmd, source: VK_ACCESS_MEMORY_WRITE_BIT.rawValue, destination: VK_ACCESS_ACCELERATION_STRUCTURE_READ_BIT_KHR.rawValue | VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR.rawValue)
        let arena = VulkanScratch()
        var info = VkAccelerationStructureBuildGeometryInfoKHR()
        info.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR
        info.type = structure.topLevel ? VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR : VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR
        info.flags = VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR.rawValue; info.mode = VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR
        info.dstAccelerationStructure = structure.native; info.geometryCount = UInt32(structure.geometry.count)
        info.pGeometries = arena.store(structure.geometry); info.scratchData.deviceAddress = structure.scratchAddress
        let ranges = arena.store(structure.ranges)
        withExtendedLifetime(arena) { build(cmd, 1, &info, arena.store([ranges])) }
        memoryDependency(cmd: cmd, source: VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR.rawValue,
                         destination: VK_ACCESS_ACCELERATION_STRUCTURE_READ_BIT_KHR.rawValue | VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR.rawValue)
    }
}
#endif
