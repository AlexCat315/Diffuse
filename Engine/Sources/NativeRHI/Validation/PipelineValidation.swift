import Foundation

struct PipelineUse {
    enum Kind { case graphics, mesh, compute }
    let layout: PipelineLayout
    let kind: Kind
}

extension PipelineInterfaces {
    /// One traversal per pass body. Pass-level capability checks belong to the
    /// caller, but per-command capability checks ride along here so the body is
    /// never walked twice.
    func validateCommands(_ buffer: CommandBuffer, caches: DeviceCaches, meshShadingEnabled: Bool) throws {
        for command in buffer.commands {
            switch command {
            case .renderPass(let pass): try validateRender(pass.body, caches: caches, meshShadingEnabled: meshShadingEnabled)
            case .computePass(let pass): try validateCompute(pass.body, caches: caches)
            default: break
            }
        }
    }
    private func use(_ id: UInt32, kind: PipelineUse.Kind) throws -> PipelineUse {
        guard let use = uses[id], use.kind == kind else { throw RHIError.invalidArgument("unknown pipeline or incorrect pipeline kind") }
        return use
    }
    private func binding(_ id: UInt32, slot: UInt32, pipeline: PipelineUse?, caches: DeviceCaches) throws {
        guard let pipeline, let descriptor = pipelines[pipeline.layout.id], Int(slot) < descriptor.setLayouts.count,
              descriptor.setLayouts[Int(slot)].id == caches.bindingSetLayoutID(id) else {
            throw RHIError.layoutMismatch("binding set must match the active pipeline's declared set layout")
        }
    }
    private func constants(_ data: Data, slot: UInt32, stage: ShaderStage, pipeline: PipelineUse?) throws {
        guard let pipeline, let descriptor = pipelines[pipeline.layout.id],
              let range = descriptor.pushConstants.first(where: { $0.slot == slot && $0.stage == stage }),
              !data.isEmpty, data.count % 4 == 0, data.count <= range.byteCount else {
            throw RHIError.layoutMismatch("push constant data must match a declared range in the active pipeline")
        }
    }
    private func validateRender(_ commands: [RenderCommand], caches: DeviceCaches, meshShadingEnabled: Bool) throws {
        var pipeline: PipelineUse?
        var indexed = false
        for command in commands {
            switch command {
            case .setPipeline(let handle): pipeline = try use(handle.id, kind: .graphics)
            case .setMeshPipeline(let handle):
                guard meshShadingEnabled else {
                    throw RHIError.unsupportedFeature("mesh commands are not implemented by this backend")
                }
                pipeline = try use(handle.id, kind: .mesh)
            case .setBindingSet(let slot, let handle): try binding(handle.id, slot: slot, pipeline: pipeline, caches: caches)
            case .pushConstant(let stage, let slot, let data): try constants(data, slot: slot, stage: stage, pipeline: pipeline)
            case .setIndexBuffer(_, let offset, let type):
                try rhiRequire(offset >= 0 && offset % (type == .uint32 ? 4 : 2) == 0, "invalid index buffer offset"); indexed = true
            case .setVertexBuffer(_, _, let offset): try rhiRequire(offset >= 0, "negative vertex buffer offset")
            case .draw(let vertices, let instances, let firstVertex, let firstInstance):
                try rhiRequire(pipeline?.kind == .graphics, "draw requires a graphics pipeline")
                for count in [vertices, instances, firstVertex, firstInstance] { _ = try rhiCount(count) }
            case .drawIndexed(let args):
                try rhiRequire(indexed && pipeline?.kind == .graphics, "indexed draw requires a graphics pipeline and index buffer")
                for count in [args.indexCount, args.instanceCount, args.firstIndex, args.firstInstance] { _ = try rhiCount(count) }
                try rhiRequire(Int32(exactly: args.vertexOffset) != nil, "vertex offset exceeds Int32")
            case .drawIndirect(_, let offset, let count):
                try rhiRequire(pipeline?.kind == .graphics && offset >= 0 && offset % 4 == 0, "invalid indirect draw pipeline or offset"); _ = try rhiCount(count)
            case .drawMeshTasks(let groups):
                guard meshShadingEnabled else {
                    throw RHIError.unsupportedFeature("mesh commands are not implemented by this backend")
                }
                try rhiRequire(pipeline?.kind == .mesh, "mesh dispatch requires a mesh pipeline"); try groups.validate()
            case .setScissor(let rect):
                try rhiRequire(rect.x >= 0 && rect.y >= 0 && rect.width >= 0 && rect.height >= 0
                    && rect.x <= Int(Int32.max) - rect.width && rect.y <= Int(Int32.max) - rect.height, "scissor exceeds Int32 extent")
            case .setViewport(let value):
                try rhiRequire([value.x, value.y, value.width, value.height, value.minDepth, value.maxDepth].allSatisfy(\.isFinite)
                    && value.width > 0 && value.height > 0 && value.minDepth >= 0 && value.maxDepth <= 1
                    && value.minDepth <= value.maxDepth, "invalid viewport")
            }
        }
    }
    private func validateCompute(_ commands: [ComputeCommand], caches: DeviceCaches) throws {
        var pipeline: PipelineUse?
        for command in commands {
            switch command {
            case .setPipeline(let handle): pipeline = try use(handle.id, kind: .compute)
            case .setBindingSet(let slot, let handle): try binding(handle.id, slot: slot, pipeline: pipeline, caches: caches)
            case .pushConstant(let stage, let slot, let data): try constants(data, slot: slot, stage: stage, pipeline: pipeline)
            case .dispatch(let x, let y, let z):
                try rhiRequire(pipeline != nil && x > 0 && y > 0 && z > 0, "dispatch requires a pipeline and positive workgroups")
                for count in [x, y, z] { _ = try rhiCount(count) }
            case .dispatchIndirect(_, let offset):
                try rhiRequire(pipeline != nil && offset >= 0 && offset % 4 == 0, "indirect dispatch requires a pipeline and aligned offset")
            }
        }
    }
}
