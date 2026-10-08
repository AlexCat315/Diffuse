// NativeRHI — frontend Device.
//
// The Device is the public entry point. It owns:
//   * monotonic handle allocation (IdentifierPool),
//   * binding-layout / binding-set / pipeline-layout caches (DeviceCaches),
//   * the frames-in-flight ring + deferred destruction (FrameRing),
//   * the SubmissionPlanner that turns recorded commands into a SubmitPlan,
// and delegates all concrete GPU work to the selected RHIBackend.
//
// All mutating operations are serialized on `lock`. Resource destruction is
// deferred to the frame's GPU completion instead of freeing live objects.

import Foundation

/// Monotonic handle allocator. A single counter across all resource kinds
/// guarantees no two live handles share an ID (ID 0 is reserved/invalid).
final class IdentifierPool {
    private var nextID: UInt32 = 1

    func next() -> UInt32 {
        let id = nextID
        nextID += 1
        precondition(nextID != 0, "RHI handle counter overflowed")
        return id
    }
}

public final class Device {
    /// The graphics API of the selected backend.
    public let backendAPI: GraphicsAPI
    /// Features implemented by this backend and supported by the selected device.
    public let capabilities: Capabilities
    public let adapterCapabilities: AdapterCapabilities
    /// The configuration the device was created with.
    public let config: DeviceConfig

    private let backend: RHIBackend
    private let frameRing: FrameRing
    private let planner = SubmissionPlanner()
    private let caches = DeviceCaches()
    private let interfaces = PipelineInterfaces()
    private var accelerationBuildInputs: [UInt32: [ResourceRef]] = [:]
    private let identifiers = IdentifierPool()
    private let lock = NSLock()
    private var currentSlot: FrameRing.Slot?
    private var currentUploader: FrameUploader?
    private var submissionFault: RHIError?

    private init(backend: RHIBackend, config: DeviceConfig) throws {
        self.backend = backend
        self.config = config
        self.capabilities = backend.queryCapabilities()
        self.adapterCapabilities = backend.queryAdapterCapabilities()
        self.frameRing = FrameRing(slotCount: max(1, config.framesInFlight))
        self.backendAPI = backend.api
    }

    /// Creates a device, trying the configured backends in order and using the
    /// first that constructs successfully.
    public static func make(_ config: DeviceConfig = DeviceConfig()) throws -> Device {
        var lastError: Error?

        for api in config.preferredBackends {
            guard NativeRHI.isCompiledIn(api) else {
                lastError = RHIError.unsupportedBackend("\(api.displayName) is not built for this platform")
                continue
            }
            do {
                let backend = try BackendFactory.makeBackend(api, config: config)
                return try Device(backend: backend, config: config)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RHIError.unsupportedBackend("no usable graphics backend")
    }

    /// Human-readable physical device / adapter name.
    public var deviceName: String { backend.deviceName }

    // MARK: Surface

    public func configureSurface(_ descriptor: SurfaceDescriptor) throws {
        try locked { try backend.configure(surface: descriptor) }
    }

    // MARK: Resources

    public func makeBuffer(_ descriptor: BufferDescriptor) throws -> Buffer {
        try locked {
            try rhiRequire(descriptor.size > 0, "buffer size must be positive")
            let handle = Buffer(id: identifiers.next())
            try backend.createBuffer(handle, descriptor: descriptor)
            return handle
        }
    }

    public func makeTexture(_ descriptor: TextureDescriptor) throws -> Texture {
        try locked {
            try rhiRequire(descriptor.width > 0 && descriptor.height > 0 && descriptor.depth > 0
                && descriptor.layers > 0 && descriptor.mipLevels > 0 && descriptor.sampleCount > 0,
                "texture dimensions, layers, mips and samples must be positive")
            if descriptor.dimension == .texture3D {
                try rhiRequire(descriptor.layers == 1, "3D textures cannot have array layers")
            } else {
                try rhiRequire(descriptor.depth == 1, "2D and cube textures require depth one")
            }
            if descriptor.dimension == .texture2D { try rhiRequire(descriptor.layers == 1, "use texture2DArray for array layers") }
            if descriptor.dimension == .cube { try rhiRequire(descriptor.layers == 1 && descriptor.width == descriptor.height, "cube textures require six square faces in one cube") }
            try rhiRequire(descriptor.format != .invalid, "texture format must be valid")
            let handle = Texture(id: identifiers.next())
            try backend.createTexture(handle, descriptor: descriptor)
            return handle
        }
    }

    public func makeSampler(_ descriptor: SamplerDescriptor = SamplerDescriptor()) throws -> Sampler {
        try locked {
            let handle = Sampler(id: identifiers.next())
            try backend.createSampler(handle, descriptor: descriptor)
            return handle
        }
    }

    public func makeShaderModule(_ descriptor: ShaderModuleDescriptor) throws -> ShaderModule {
        try locked {
            try descriptor.threadgroupSize.validate()
            try rhiRequire(!descriptor.code.isEmpty && !descriptor.entryPoint.isEmpty,
                           "shader code and entry point must be non-empty")
            if descriptor.stage == .task && !capabilities.meshShading.task {
                throw RHIError.unsupportedFeature("task shaders are not implemented by this backend")
            }
            if descriptor.stage == .mesh || descriptor.stage == .task {
                guard capabilities.meshShading.mesh else {
                    throw RHIError.unsupportedFeature("mesh shading is not implemented by this backend")
                }
            }
            let handle = ShaderModule(id: identifiers.next())
            try backend.createShaderModule(handle, descriptor: descriptor)
            return handle
        }
    }

    public func makeAccelerationStructure(_ descriptor: AccelerationStructureDescriptor) throws -> AccelerationStructure {
        try locked {
            guard capabilities.rayTracing.accelerationStructures else {
                throw RHIError.unsupportedFeature("acceleration structures are not implemented by this backend")
            }
            switch descriptor {
            case .bottomLevel(let triangles):
                try rhiRequire(!triangles.isEmpty && triangles.allSatisfy { $0.triangleCount > 0 && $0.triangleCount <= Int(UInt32.max / 3)
                    && $0.vertexOffset >= 0 && $0.vertexOffset % 4 == 0 && $0.vertexStride >= 12
                    && $0.vertexStride <= Int(UInt32.max) && $0.vertexStride % 4 == 0 }, "invalid triangle geometry")
            case .topLevel(let instances):
                try rhiRequire(!instances.isEmpty && instances.count <= 0x100_0000 && instances.allSatisfy { instance in
                    instance.mask <= 255 && [instance.transform.x, instance.transform.y, instance.transform.z].allSatisfy { row in
                        [row.x, row.y, row.z, row.w].allSatisfy(\.isFinite)
                    }
                }, "invalid acceleration instance")
            }
            let handle = AccelerationStructure(id: identifiers.next())
            try backend.createAccelerationStructure(handle, descriptor: descriptor)
            switch descriptor {
            case .bottomLevel(let geometries):
                accelerationBuildInputs[handle.id] = geometries.map { ResourceRef(kind: .buffer, id: $0.vertices.id) }
            case .topLevel(let instances):
                accelerationBuildInputs[handle.id] = instances.map { ResourceRef(kind: .accelerationStructure, id: $0.structure.id) }
            }
            return handle
        }
    }

    public func recordBuild(_ structure: AccelerationStructure, into commands: CommandBuffer) throws {
        try locked {
            guard let inputs = accelerationBuildInputs[structure.id] else {
                throw RHIError.invalidArgument("unknown acceleration structure")
            }
            commands.buildAccelerationStructure(AccelerationStructureBuild(structure: structure, inputs: inputs))
        }
    }

    public func destroy(_ structure: AccelerationStructure) {
        locked {
            accelerationBuildInputs[structure.id] = nil
            planner.forgetResource(ResourceRef(kind: .accelerationStructure, id: structure.id))
            frameRing.retireCurrent { [backend] in backend.destroyAccelerationStructure(structure) }
        }
    }

    // MARK: Resource destruction (deferred)

    public func destroy(_ buffer: Buffer) {
        locked {
            planner.forgetResource(ResourceRef(kind: .buffer, id: buffer.id))
            frameRing.retireCurrent { [backend] in backend.destroyBuffer(buffer) }
        }
    }

    public func destroy(_ texture: Texture) {
        locked {
            planner.forgetResource(ResourceRef(kind: .texture, id: texture.id))
            frameRing.retireCurrent { [backend] in backend.destroyTexture(texture) }
        }
    }

    public func destroy(_ sampler: Sampler) {
        locked { frameRing.retireCurrent { [backend] in backend.destroySampler(sampler) } }
    }

    public func destroy(_ shader: ShaderModule) {
        locked { frameRing.retireCurrent { [backend] in backend.destroyShaderModule(shader) } }
    }

    // MARK: Pipelines

    public func makeGraphicsPipeline(_ descriptor: GraphicsPipelineDescriptor) throws -> GraphicsPipeline {
        try locked {
            guard capabilities.graphics else {
                throw RHIError.unsupportedFeature("graphics pipelines are not implemented by this backend")
            }
            try rhiRequire(interfaces.pipelines[descriptor.layout.id] != nil, "unknown pipeline layout")
            guard descriptor.stencilFormat == nil else { throw RHIError.unsupportedFeature("stencil pipeline state is not implemented") }
            let handle = GraphicsPipeline(id: identifiers.next())
            try backend.createGraphicsPipeline(handle, descriptor: descriptor)
            interfaces.uses[handle.id] = PipelineUse(layout: descriptor.layout, kind: .graphics)
            return handle
        }
    }

    public func makeMeshPipeline(_ descriptor: MeshPipelineDescriptor) throws -> MeshPipeline {
        try locked {
            guard capabilities.meshShading.mesh else {
                throw RHIError.unsupportedFeature("mesh pipelines are not implemented by this backend")
            }
            try rhiRequire(interfaces.pipelines[descriptor.layout.id] != nil, "unknown pipeline layout")
            let handle = MeshPipeline(id: identifiers.next())
            try backend.createMeshPipeline(handle, descriptor: descriptor)
            interfaces.uses[handle.id] = PipelineUse(layout: descriptor.layout, kind: .mesh)
            return handle
        }
    }

    public func destroy(_ pipeline: MeshPipeline) {
        locked { interfaces.uses[pipeline.id] = nil; frameRing.retireCurrent { [backend] in backend.destroyMeshPipeline(pipeline) } }
    }

    public func makeComputePipeline(_ descriptor: ComputePipelineDescriptor) throws -> ComputePipeline {
        try locked {
            guard capabilities.compute else {
                throw RHIError.unsupportedFeature("compute pipelines are not implemented by this backend")
            }
            try rhiRequire(interfaces.pipelines[descriptor.layout.id] != nil, "unknown pipeline layout")
            let handle = ComputePipeline(id: identifiers.next())
            try backend.createComputePipeline(handle, descriptor: descriptor)
            interfaces.uses[handle.id] = PipelineUse(layout: descriptor.layout, kind: .compute)
            return handle
        }
    }

    public func destroy(_ pipeline: GraphicsPipeline) {
        locked { interfaces.uses[pipeline.id] = nil; frameRing.retireCurrent { [backend] in backend.destroyGraphicsPipeline(pipeline) } }
    }

    public func destroy(_ pipeline: ComputePipeline) {
        locked { interfaces.uses[pipeline.id] = nil; frameRing.retireCurrent { [backend] in backend.destroyComputePipeline(pipeline) } }
    }

    // MARK: Binding layouts / sets / pipeline layouts

    public func makeBindingLayout(_ descriptor: BindingLayoutDescriptor) throws -> BindingLayout {
        try locked {
            try rhiRequire(Set(descriptor.entries.map(\.slot)).count == descriptor.entries.count,
                           "binding layout contains duplicate slots")
            guard descriptor.entries.allSatisfy({ $0.arraySize == 1 }) else {
                throw RHIError.unsupportedFeature("binding arrays are not implemented")
            }
            try rhiRequire(descriptor.entries.allSatisfy { $0.type != .accelerationStructure || $0.visibility == .compute }, "acceleration structure bindings currently support compute ray queries")
            if descriptor.entries.contains(where: { $0.type == .accelerationStructure }),
               !capabilities.rayTracing.accelerationStructures {
                throw RHIError.unsupportedFeature("acceleration structure bindings are unavailable")
            }
            try rhiRequire(descriptor.entries.allSatisfy { !$0.visibility.isEmpty && $0.visibility.subtracting(.all).isEmpty }, "invalid shader visibility")
            if descriptor.entries.contains(where: { $0.visibility.contains(.mesh) }), !capabilities.meshShading.mesh { throw RHIError.unsupportedFeature("mesh visibility is unavailable") }
            if descriptor.entries.contains(where: { $0.visibility.contains(.task) }), !capabilities.meshShading.task { throw RHIError.unsupportedFeature("task visibility is unavailable") }
            try rhiRequire(descriptor.entries.allSatisfy { $0.buffer.elementStride >= 0 }, "negative storage element stride")
            let handle = BindingLayout(id: identifiers.next())
            try backend.registerBindingLayout(handle, descriptor: descriptor)
            caches.storeBindingLayout(handle.id, entries: descriptor.entries)
            interfaces.bindings[handle.id] = descriptor
            return handle
        }
    }

    public func makePipelineLayout(_ descriptor: PipelineLayoutDescriptor) throws -> PipelineLayout {
        try locked {
            try interfaces.validate(descriptor)
            let setIDs = descriptor.setLayouts.map(\.id)
            for setID in setIDs where caches.bindingLayoutEntries(setID) == nil {
                throw RHIError.invalidArgument("pipeline layout references an unknown binding layout")
            }
            let key = PipelineInterfaceKey(setLayouts: setIDs, pushConstants: descriptor.pushConstants)
            if let existing = caches.pipelineLayouts.layout(for: key) {
                return PipelineLayout(id: existing)
            }
            let handle = PipelineLayout(id: identifiers.next())
            try backend.registerPipelineLayout(handle, descriptor: descriptor)
            interfaces.pipelines[handle.id] = descriptor
            caches.pipelineLayouts.insert(handle.id, for: key)
            caches.storePipelineLayoutDefinition(handle.id, setLayouts: setIDs)
            return handle
        }
    }

    public func makeBindingSet(layout: BindingLayout, descriptor: BindingSetDescriptor) throws -> BindingSet {
        try locked {
            guard let layoutEntries = caches.bindingLayoutEntries(layout.id) else {
                throw RHIError.invalidArgument("unknown binding layout")
            }
            try validateBindingSet(descriptor, layoutEntries: layoutEntries)

            if let existing = caches.bindingSets.existing(layoutID: layout.id, entries: descriptor.entries) {
                return BindingSet(id: existing)
            }
            if let evicted = caches.bindingSets.evictIfFull() {
                teardownBindingSet(evicted)
            }

            let handle = BindingSet(id: identifiers.next())
            caches.bindingSets.insert(handle.id, layoutID: layout.id, entries: descriptor.entries)
            caches.storeBindingSet(handle.id, layoutID: layout.id)
            planner.registerBindingSetEntries(handle.id, entries: descriptor.entries,
                readOnlySlots: Set(layoutEntries.filter { $0.buffer.readOnly }.map(\.slot)))

            do {
                try backend.registerBindingSet(handle, layout: layout, layoutEntries: layoutEntries, setEntries: descriptor.entries)
            } catch {
                // Roll back the frontend so we never hold a set the backend lacks
                // (the Zig prototype silently swallowed this and mis-bound).
                caches.bindingSets.remove(layoutID: layout.id, entries: descriptor.entries)
                caches.removeBindingSetOwner(handle.id)
                planner.removeBindingSetEntries(handle.id)
                throw error
            }
            return handle
        }
    }

    private func teardownBindingSet(_ handleID: UInt32) {
        caches.removeBindingSetOwner(handleID)
        planner.removeBindingSetEntries(handleID)
        let handle = BindingSet(id: handleID)
        frameRing.retireCurrent { [backend] in backend.unregisterBindingSet(handle) }
    }

    private func validateBindingSet(
        _ descriptor: BindingSetDescriptor,
        layoutEntries: [BindingLayoutEntry]
    ) throws {
        guard descriptor.entries.count == layoutEntries.count else {
            throw RHIError.layoutMismatch(
                "binding set has \(descriptor.entries.count) entries; layout expects \(layoutEntries.count)"
            )
        }
        for layoutEntry in layoutEntries {
            guard let entry = descriptor.entries.first(where: { $0.slot == layoutEntry.slot }) else {
                throw RHIError.layoutMismatch("binding set is missing entry for slot \(layoutEntry.slot)")
            }
            guard resourceMatches(entry.resource, type: layoutEntry.type) else {
                throw RHIError.layoutMismatch(
                    "resource at slot \(layoutEntry.slot) does not match the declared binding type"
                )
            }
        }
    }

    private func resourceMatches(_ resource: BindingResource, type: BindingType) -> Bool {
        switch (resource, type) {
        case (.sampler, .sampler),
             (.texture, .texture),
             (.storageTexture, .storageTexture),
             (.uniformBuffer, .uniformBuffer),
             (.storageBuffer, .storageBuffer),
             (.accelerationStructure, .accelerationStructure):
            return true
        default:
            return false
        }
    }

    // MARK: Frame lifecycle

    /// Begins a frame, blocking the CPU only if the chosen slot's prior frame
    /// is still executing on the GPU.
    public func beginFrame() throws {
        try locked {
            guard currentSlot == nil else { throw RHIError.invalidArgument("a frame is already active") }
            let slot = frameRing.begin()
            do {
                let uploader = try backend.makeFrameUploader(slot: slot.index)
                uploader.reset(); currentSlot = slot; currentUploader = uploader
            } catch {
                frameRing.end()
                throw error
            }
        }
    }

    /// Ends the frame and releases the per-frame upload context.
    public func endFrame() {
        locked {
            frameRing.end()
            currentSlot = nil
            currentUploader = nil
        }
    }

    /// Suballocates transient per-frame storage (for push constants / small
    /// constants) and returns the buffer + offset to bind.
    public func uploadTransient(_ data: Data, alignment: Int = 256) throws -> UploadLocation {
        try locked {
            guard let uploader = currentUploader else { throw RHIError.frameNotActive }
            return try uploader.write(data, alignment: alignment)
        }
    }

    // MARK: Submission

    /// Plans and submits a recorded command buffer. Submission is asynchronous;
    /// completion is tracked against the current frame slot.
    public func submit(
        _ commandBuffer: CommandBuffer,
        queue: QueueClass = .graphics,
        waits: [TimelineSemaphore] = [],
        signals: [TimelineSemaphore] = []
    ) throws {
        try locked {
            guard let slot = currentSlot else { throw RHIError.frameNotActive }
            if let submissionFault { throw submissionFault }
            let queueCount: UInt8
            switch queue {
            case .graphics: queueCount = capabilities.maxQueues.graphics
            case .compute: queueCount = capabilities.maxQueues.compute
            case .transfer: queueCount = capabilities.maxQueues.transfer
            }
            guard queueCount > 0 else { throw RHIError.unsupportedFeature("requested queue is unavailable") }
            try validateCommands(commandBuffer, queue: queue)
            let rollback = planner.checkpoint()
            let plan: SubmitPlan
            do {
                plan = try planner.buildPlan(queue: queue, commands: commandBuffer.commands,
                    external: SubmitDescriptor(waitSemaphores: waits, signalSemaphores: signals))
            } catch {
                rollback()
                throw error
            }
            var submitted = false
            for plannedSubmit in plan.submits {
                frameRing.registerCommandBuffer(slotIndex: slot.index)
                do {
                    try backend.submit(plannedSubmit) { [frameRing, slot] in
                        frameRing.commandBufferCompleted(slotIndex: slot.index)
                    }
                    submitted = true
                } catch {
                    frameRing.unregisterCommandBuffer(slotIndex: slot.index)
                    if submitted {
                        submissionFault = .submitFailed("partial submission failed; recreate the device before further submissions")
                    } else {
                        rollback()
                    }
                    throw error
                }
            }
        }
    }

    private func validateCommands(_ commandBuffer: CommandBuffer, queue: QueueClass) throws {
        try interfaces.validateCommands(commandBuffer, caches: caches)
        for command in commandBuffer.commands {
            if case .accelerationStructureBuild = command, queue == .transfer { throw RHIError.invalidArgument("acceleration builds require graphics or compute queue") }
            if case .accelerationStructureBuild = command, !capabilities.rayTracing.accelerationStructures {
                throw RHIError.unsupportedFeature("acceleration structure builds are not implemented by this backend")
            }
            if case .computePass = command, !capabilities.compute {
                throw RHIError.unsupportedFeature("compute commands are not implemented by this backend")
            }
            if case .computePass = command, queue == .transfer {
                throw RHIError.invalidArgument("compute passes cannot execute on a transfer queue")
            }
            if case .renderPass(let record) = command {
                try rhiRequire(queue == .graphics, "render passes require the graphics queue")
                guard capabilities.graphics else {
                    throw RHIError.unsupportedFeature("graphics commands are not implemented by this backend")
                }
                for item in record.body {
                    switch item {
                    case .setMeshPipeline, .drawMeshTasks:
                        guard capabilities.meshShading.mesh else {
                            throw RHIError.unsupportedFeature("mesh commands are not implemented by this backend")
                        }
                    default: break
                    }
                }
            }
        }
    }

    // MARK: Swapchain

    public func acquireSwapchainImage() throws -> SwapchainImage {
        try locked {
            guard currentSlot != nil else { throw RHIError.frameNotActive }
            return try backend.acquireSwapchainImage()
        }
    }

    public func present(_ image: SwapchainImage) throws {
        try locked {
            guard currentSlot != nil else { throw RHIError.frameNotActive }
            try backend.present(image)
        }
    }

    // MARK: Immediate data transfer

    public func uploadBufferData(_ buffer: Buffer, offset: Int = 0, data: Data) throws {
        try locked {
            try backend.uploadBufferData(buffer, offset: offset, data: data)
            if !data.isEmpty { planner.recordImmediateWrite(ResourceRef(kind: .buffer, id: buffer.id)) }
        }
    }

    public func uploadTextureData(
        _ texture: Texture,
        data: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws {
        try locked {
            try backend.uploadTextureData(
                texture, data: data, width: width, height: height, bytesPerRow: bytesPerRow
            )
            planner.recordImmediateWrite(ResourceRef(kind: .texture, id: texture.id))
        }
    }

    public func readTextureData(
        _ texture: Texture,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        into destination: UnsafeMutableRawBufferPointer
    ) throws {
        try locked {
            try backend.readTextureData(
                texture, width: width, height: height,
                bytesPerRow: bytesPerRow, into: destination
            )
        }
    }

    // MARK: Caches / diagnostics

    public var bindingSetCacheStats: CacheStats {
        locked { caches.bindingSets.stats }
    }

    /// Blocks until all queued GPU work has completed.
    public func waitUntilIdle() throws {
        try locked {
            guard currentSlot == nil else {
                throw RHIError.invalidArgument("endFrame must precede waitUntilIdle")
            }
            frameRing.waitUntilIdle()
            try backend.waitUntilIdle()
        }
    }

    // MARK: Lock helper

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
