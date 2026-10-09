import CDX12Bridge
import Foundation

/// Retains the backend and callback until native fence completion. Native submit
/// consumes this reference exactly once after successfully queuing the work.
final class DX12Completion {
    let backend: DX12Device
    let callback: () -> Void
    init(backend: DX12Device, callback: @escaping () -> Void) { self.backend = backend; self.callback = callback }
}

extension DX12Device {
    public func submit(_ submit: PlannedSubmit, cpuProfile: SubmissionCPUProfile? = nil, completion: @escaping () -> Void) throws {
        let encodingStart = cpuProfile?.begin()
        guard let encoder = grhi_dx12_begin(native, UInt32(submit.queue.rawValue)) else { try check(0); return }
        var consumed = false
        defer { if !consumed { grhi_dx12_abort(encoder) } }
        for command in submit.commands {
            switch command {
            case .accelerationStructureBuild(let build): try emit(encoder, kind: 19, resource: build.structure.id)
            case .barriers(let barriers):
                for barrier in barriers {
                    let kind: UInt32
                    switch barrier.resource.kind { case .buffer: kind = 0; case .texture: kind = 1; case .accelerationStructure: kind = 2 }
                    try emit(encoder, kind: 18, resource: barrier.resource.id, slot: kind, a: UInt64(barrier.destinationState.rawValue), b: UInt64(barrier.syncAction.rawValue))
                }
            case .renderPass(let pass):
                try beginRender(encoder, descriptor: pass.descriptor)
                for command in pass.body { try render(encoder, command: command) }
                try emit(encoder, kind: 20)
            case .computePass(let pass): for command in pass.body { try compute(encoder, command: command) }
            case .copyPass(let pass): for command in pass.body { try copy(encoder, command: command) }
            }
        }
        let waits = submit.waitSemaphores.map { GRHI_Timeline(id: $0.id, value: $0.value) }
        let signals = submit.signalSemaphores.map { GRHI_Timeline(id: $0.id, value: $0.value) }
        let retained = Unmanaged.passRetained(DX12Completion(backend: self, callback: completion)).toOpaque()
        cpuProfile?.end(.encoding, since: encodingStart)
        let queueStart = cpuProfile?.begin()
        let result = waits.withUnsafeBufferPointer { w in signals.withUnsafeBufferPointer { s in
            grhi_dx12_submit(encoder, w.baseAddress, w.count, s.baseAddress, s.count, { context in
                guard let context else { return }
                Unmanaged<DX12Completion>.fromOpaque(context).takeRetainedValue().callback()
            }, retained)
        } }
        if result == 0 { Unmanaged<DX12Completion>.fromOpaque(retained).release(); try check(0) }
        cpuProfile?.end(.queueSubmit, since: queueStart)
        consumed = true
    }
    private func beginRender(_ encoder: OpaquePointer, descriptor: RenderPassDescriptor) throws {
        let colors = descriptor.colorTargets.map { c -> GRHI_RenderColor in
            var result = GRHI_RenderColor(); result.texture = c.texture.id; result.store = c.store ? 1 : 0
            result.resolve = c.resolveTexture?.id ?? 0
            switch c.loadAction {
            case .load: result.load = 0
            case .clear(let color): result.load = 1; result.clear = (color.x, color.y, color.z, color.w)
            case .dontCare: result.load = 2
            }
            return result
        }
        var depth: GRHI_RenderDepth?
        if let d = descriptor.depthTarget {
            var native = GRHI_RenderDepth(); native.texture = d.texture.id; native.store = d.store ? 1 : 0
            switch d.loadAction { case .load: native.load = 0; case .clear(let value): native.load = 1; native.clear = Float(value); case .dontCare: native.load = 2 }
            depth = native
        }
        try colors.withUnsafeBufferPointer { colors in
            if var depth { try check(grhi_dx12_render(encoder, colors.baseAddress, colors.count, &depth)) }
            else { try check(grhi_dx12_render(encoder, colors.baseAddress, colors.count, nil)) }
        }
    }
    private func emit(_ encoder: OpaquePointer, kind: UInt32, resource: UInt32 = 0, slot: UInt32 = 0, stage: UInt32 = 0, a: UInt64 = 0, b: UInt64 = 0, c: UInt64 = 0, d: UInt64 = 0, data: Data = Data()) throws {
        try data.withUnsafeBytes { bytes in
            var command = GRHI_DX12Command(kind: kind, resource: resource, slot: slot, stage: stage, a: a, b: b, c: c, d: d, data: bytes.baseAddress, bytes: bytes.count)
            try check(grhi_dx12_encode(encoder, &command))
        }
    }
    private func render(_ e: OpaquePointer, command: RenderCommand) throws {
        switch command {
        case .setPipeline(let p): try emit(e, kind: 0, resource: p.id)
        case .setMeshPipeline(let p): try emit(e, kind: 2, resource: p.id)
        case .drawMeshTasks(let groups): try emit(e, kind: 14, a: UInt64(rhiCount(groups.x)), b: UInt64(rhiCount(groups.y)), c: UInt64(rhiCount(groups.z)))
        case .setBindingSet(let slot, let set): try emit(e, kind: 3, resource: set.id, slot: slot)
        case .setVertexBuffer(let slot, let buffer, let offset): try emit(e, kind: 4, resource: buffer.id, slot: slot, a: nonnegative(offset))
        case .setIndexBuffer(let buffer, let offset, let type): try emit(e, kind: 5, resource: buffer.id, a: nonnegative(offset), b: type == .uint32 ? 1 : 0)
        case .pushConstant(let stage, let slot, let data): try emit(e, kind: 6, slot: slot, stage: stage.dx12, data: data)
        case .setViewport(let v):
            var values = [Float(v.x), Float(v.y), Float(v.width), Float(v.height), Float(v.minDepth), Float(v.maxDepth)]
            try values.withUnsafeMutableBytes { try emit(e, kind: 7, data: Data($0)) }
        case .setScissor(let s): try emit(e, kind: 8, a: UInt64(rhiCount(s.x)), b: UInt64(rhiCount(s.y)), c: UInt64(rhiCount(s.width)), d: UInt64(rhiCount(s.height)))
        case .draw(let count, let instances, let first, let instance): try emit(e, kind: 9, a: UInt64(rhiCount(count)), b: UInt64(rhiCount(instances)), c: UInt64(rhiCount(first)), d: UInt64(rhiCount(instance)))
        case .drawIndexed(let args):
            guard Int32(exactly: args.vertexOffset) != nil else { throw RHIError.invalidArgument("vertex offset exceeds Int32") }
            try emit(e, kind: 10, slot: rhiCount(args.firstInstance), a: UInt64(rhiCount(args.indexCount)), b: UInt64(rhiCount(args.instanceCount)), c: UInt64(rhiCount(args.firstIndex)), d: UInt64(bitPattern: Int64(args.vertexOffset)))
        case .drawIndirect(let buffer, let offset, let count): try emit(e, kind: 11, resource: buffer.id, a: nonnegative(offset), b: UInt64(rhiCount(count)))
        }
    }
    private func compute(_ e: OpaquePointer, command: ComputeCommand) throws {
        switch command {
        case .setPipeline(let p): try emit(e, kind: 1, resource: p.id)
        case .setBindingSet(let slot, let set): try emit(e, kind: 3, resource: set.id, slot: slot)
        case .pushConstant(let stage, let slot, let data): try emit(e, kind: 6, slot: slot, stage: stage.dx12, data: data)
        case .dispatch(let x, let y, let z): try emit(e, kind: 12, a: UInt64(rhiCount(x)), b: UInt64(rhiCount(y)), c: UInt64(rhiCount(z)))
        case .dispatchIndirect(let buffer, let offset): try emit(e, kind: 13, resource: buffer.id, a: nonnegative(offset))
        }
    }
    private func copy(_ e: OpaquePointer, command: CopyCommand) throws {
        switch command {
        case .copyTexture(let src, let dst, let width, let height):
            try emit(e, kind: 21, resource: src.id, slot: dst.id, a: UInt64(rhiCount(width)), b: UInt64(rhiCount(height)))
        case .copyBuffer(let src, let srcOffset, let dst, let dstOffset, let size): try emit(e, kind: 15, resource: src.id, slot: dst.id, a: nonnegative(srcOffset), b: nonnegative(dstOffset), c: nonnegative(size))
        case .copyBufferToTexture(let upload):
            var region = try GRHI_TextureRegion(origin_x: rhiCount(upload.region.origin.x), origin_y: rhiCount(upload.region.origin.y),
                width: rhiCount(upload.region.width), height: rhiCount(upload.region.height),
                mip: rhiCount(upload.subresource.mipLevel), layer: rhiCount(upload.subresource.layer))
            try withUnsafeBytes(of: &region) {
                try emit(e, kind: 16, resource: upload.buffer.id, slot: upload.texture.id,
                    a: nonnegative(upload.offset), b: UInt64(rhiCount(upload.bytesPerRow)), data: Data($0))
            }
        case .copyTextureToBuffer(let texture, let width, let height, let buffer, let offset, let row): try emit(e, kind: 17, resource: buffer.id, slot: texture.id, a: nonnegative(offset), b: UInt64(rhiCount(row)), c: UInt64(rhiCount(width)), d: UInt64(rhiCount(height)))
        }
    }
}
