#if os(macOS)
import Metal

struct MetalAccelerationStructure {
    let structure: MTLAccelerationStructure
    let descriptor: MTLAccelerationStructureDescriptor
    let scratchSize: Int
    let dependencies: [MTLResource]
}

extension MetalDevice {
    public func createAccelerationStructure(_ handle: AccelerationStructure,
                                            descriptor: AccelerationStructureDescriptor) throws {
        guard device.supportsRaytracing else {
            throw RHIError.unsupportedFeature("adapter has no ray tracing support")
        }
        let native: MTLAccelerationStructureDescriptor
        var dependencies: [MTLResource] = []
        switch descriptor {
        case .bottomLevel(let geometries):
            try rhiRequire(!geometries.isEmpty, "BLAS requires triangle geometry")
            let primitive = MTLPrimitiveAccelerationStructureDescriptor()
            primitive.geometryDescriptors = try geometries.map { geometry in
                guard let buffer = registries.buffers[geometry.vertices.id] else {
                    throw RHIError.invalidArgument("BLAS references an unknown vertex buffer")
                }
                try rhiRequire(geometry.triangleCount > 0 && geometry.vertexOffset >= 0 && geometry.vertexOffset % 4 == 0
                    && geometry.vertexStride >= 12 && geometry.vertexStride % 4 == 0,
                    "invalid triangle geometry dimensions")
                let (vertices, overflowCount) = geometry.triangleCount.multipliedReportingOverflow(by: 3)
                try rhiRequire(!overflowCount, "triangle count overflows")
                let (lastOffset, overflowStride) = (vertices - 1).multipliedReportingOverflow(by: geometry.vertexStride)
                let (end, overflowEnd) = geometry.vertexOffset.addingReportingOverflow(lastOffset)
                try rhiRequire(!overflowCount && !overflowStride && !overflowEnd && end <= buffer.length - 12,
                               "triangle geometry exceeds vertex buffer")
                let result = MTLAccelerationStructureTriangleGeometryDescriptor()
                result.vertexBuffer = buffer
                result.vertexBufferOffset = geometry.vertexOffset
                result.vertexStride = geometry.vertexStride
                result.triangleCount = geometry.triangleCount
                result.opaque = true
                dependencies.append(buffer)
                return result
            }
            native = primitive
        case .topLevel(let instances):
            try rhiRequire(!instances.isEmpty, "TLAS requires instances")
            let instance = MTLInstanceAccelerationStructureDescriptor()
            var structures: [MTLAccelerationStructure] = []
            var packed: [MTLAccelerationStructureInstanceDescriptor] = []
            for (index, value) in instances.enumerated() {
                guard let child = registries.accelerationStructures[value.structure.id],
                      child.descriptor is MTLPrimitiveAccelerationStructureDescriptor else {
                    throw RHIError.invalidArgument("TLAS instances must reference live BLAS handles")
                }
                let transform = value.transform
                try rhiRequire([transform.x, transform.y, transform.z].allSatisfy { row in
                    (0..<4).allSatisfy { row[$0].isFinite }
                }, "instance transform must contain finite values")
                var record = MTLAccelerationStructureInstanceDescriptor()
                record.transformationMatrix.columns = (
                    MTLPackedFloat3Make(transform.x.x, transform.y.x, transform.z.x),
                    MTLPackedFloat3Make(transform.x.y, transform.y.y, transform.z.y),
                    MTLPackedFloat3Make(transform.x.z, transform.y.z, transform.z.z),
                    MTLPackedFloat3Make(transform.x.w, transform.y.w, transform.z.w))
                record.options = .opaque
                record.mask = value.mask
                record.accelerationStructureIndex = UInt32(index)
                structures.append(child.structure)
                dependencies.append(child.structure)
                packed.append(record)
            }
            let bytes = packed.withUnsafeBytes { Data($0) }
            guard let buffer = bytes.withUnsafeBytes({ raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
            }) else { throw RHIError.outOfMemory }
            dependencies.append(buffer)
            instance.instanceDescriptorBuffer = buffer
            instance.instanceCount = instances.count
            instance.instancedAccelerationStructures = structures
            native = instance
        }
        let sizes = device.accelerationStructureSizes(descriptor: native)
        guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize) else {
            throw RHIError.outOfMemory
        }
        registries.accelerationStructures[handle.id] = MetalAccelerationStructure(
            structure: structure, descriptor: native, scratchSize: sizes.buildScratchBufferSize,
            dependencies: dependencies)
    }

    public func destroyAccelerationStructure(_ handle: AccelerationStructure) {
        registries.accelerationStructures[handle.id] = nil
    }
}
#endif
