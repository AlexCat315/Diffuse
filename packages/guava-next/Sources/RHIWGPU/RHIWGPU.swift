import CWGPUBridge
import Foundation

public enum WGPUBackendState: Sendable {
    case uninitialized
    case bridgeReady
    case instanceReady
    case adapterReady
    case deviceReady
}

public struct WGPUDeviceConfig: Sendable {
    public var validationEnabled: Bool
    public var framesInFlight: UInt32
    public var libraryPath: String?

    public init(validationEnabled: Bool = true, framesInFlight: UInt32 = 2, libraryPath: String? = nil) {
        self.validationEnabled = validationEnabled
        self.framesInFlight = framesInFlight
        self.libraryPath = libraryPath
    }
}

public enum WGPUBackendError: Error {
    case bridgeInitializeFailed(String)
    case createInstanceFailed(String)
    case requestAdapterFailed(String)
    case requestDeviceFailed(String)
    case releaseDeviceFailed(String)
    case releaseAdapterFailed(String)
    case releaseInstanceFailed(String)
    case initFailed(String)
}

public final class WGPUBackend {
    public private(set) var state: WGPUBackendState = .uninitialized
    public private(set) var config: WGPUDeviceConfig
    private var instance: UnsafeMutableRawPointer?
    private var adapter: UnsafeMutableRawPointer?
    private var device: UnsafeMutableRawPointer?
    private var queue: UnsafeMutableRawPointer?

    public var rawDevice: UnsafeMutableRawPointer? { device }
    public var rawQueue: UnsafeMutableRawPointer? { queue }
    public var rawInstance: UnsafeMutableRawPointer? { instance }

    public init(config: WGPUDeviceConfig = .init()) {
        self.config = config
    }

    deinit {
        do {
            try shutdown()
        } catch {
            // Ignore errors during deinit; process is shutting down.
        }
    }

    public func initialize() throws {
        if state != .uninitialized {
            return
        }

        let ok: Int32
        if let path = config.libraryPath {
            ok = path.withCString { cPath in
                wgpu_bridge_initialize(cPath)
            }
        } else {
            ok = wgpu_bridge_initialize(nil)
        }
        guard ok == 1 else {
            throw WGPUBackendError.bridgeInitializeFailed(lastBridgeError())
        }
        state = .bridgeReady

        var out: UnsafeMutableRawPointer?
        let createOk = wgpu_bridge_create_instance(&out)
        guard createOk == 1, let out else {
            throw WGPUBackendError.createInstanceFailed(lastBridgeError())
        }

        instance = out
        state = .instanceReady

        var outAdapter: UnsafeMutableRawPointer?
        let adapterOk = wgpu_bridge_request_adapter(out, &outAdapter)
        guard adapterOk == 1, let outAdapter else {
            let message = lastBridgeError()
            try? shutdown()
            throw WGPUBackendError.requestAdapterFailed(message)
        }
        adapter = outAdapter
        state = .adapterReady

        var outDevice: UnsafeMutableRawPointer?
        let deviceOk = wgpu_bridge_request_device(outAdapter, &outDevice)
        guard deviceOk == 1, let outDevice else {
            let message = lastBridgeError()
            try? shutdown()
            throw WGPUBackendError.requestDeviceFailed(message)
        }
        device = outDevice
        state = .deviceReady

        var outQueue: UnsafeMutableRawPointer?
        let queueOk = wgpu_bridge_get_queue(outDevice, &outQueue)
        if queueOk == 1 {
            queue = outQueue
        }
    }

    public func shutdown() throws {
        if let queue {
            wgpu_bridge_release_queue(queue)
            self.queue = nil
        }

        if let device {
            let ok = wgpu_bridge_release_device(device)
            guard ok == 1 else {
                throw WGPUBackendError.releaseDeviceFailed(lastBridgeError())
            }
            self.device = nil
        }

        if let adapter {
            let ok = wgpu_bridge_release_adapter(adapter)
            guard ok == 1 else {
                throw WGPUBackendError.releaseAdapterFailed(lastBridgeError())
            }
            self.adapter = nil
        }

        if let instance {
            let ok = wgpu_bridge_release_instance(instance)
            guard ok == 1 else {
                throw WGPUBackendError.releaseInstanceFailed(lastBridgeError())
            }
            self.instance = nil
        }

        wgpu_bridge_shutdown()
        state = .uninitialized
    }

    private func lastBridgeError() -> String {
        Self.lastError()
    }

    static func lastError() -> String {
        guard let ptr = wgpu_bridge_last_error() else {
            return "unknown bridge error"
        }
        return String(cString: ptr)
    }

    // MARK: - Factory Methods

    public func createSurfaceMetal(layer: UnsafeMutableRawPointer) throws -> GPUSurface {
        guard let instance else {
            throw WGPUBackendError.initFailed("backend not initialized")
        }
        var surfPtr: UnsafeMutableRawPointer?
        let ok = wgpu_bridge_create_surface_metal(instance, layer, &surfPtr)
        guard ok == 1, let surfPtr else {
            throw GPUSurfaceError.createFailed(Self.lastError())
        }
        return GPUSurface(handle: surfPtr)
    }

    public func createShaderModule(wgsl: String, label: String? = nil) throws -> GPUShaderModule {
        guard let device else {
            throw WGPUBackendError.initFailed("device not ready")
        }
        var modPtr: UnsafeMutableRawPointer?
        let ok = wgsl.withCString { code in
            if let label {
                return label.withCString { lbl in
                    wgpu_bridge_create_shader_module(device, code, lbl, &modPtr)
                }
            } else {
                return wgpu_bridge_create_shader_module(device, code, nil, &modPtr)
            }
        }
        guard ok == 1, let modPtr else {
            throw WGPUBackendError.initFailed(Self.lastError())
        }
        return GPUShaderModule(handle: modPtr)
    }

    public func createRenderPipeline(desc: GPURenderPipelineDescriptor) throws -> GPURenderPipeline {
        guard let device else {
            throw WGPUBackendError.initFailed("device not ready")
        }

        var pipelinePtr: UnsafeMutableRawPointer?

        let ok = try desc.vertexEntryPoint.withCString { vEntry in
            try desc.fragmentEntryPoint.withCString { fEntry -> Int32 in

                func callCreate(layouts: UnsafePointer<WGPUBridgeVertexBufferLayout>?,
                                count: UInt32) -> Int32 {
                    var bsVal: WGPUBridgeBlendState?
                    if let blend = desc.blend { bsVal = blend.bridgeValue }
                    var dsVal: WGPUBridgeDepthStencilPipelineState?
                    if let ds = desc.depthStencil { dsVal = ds.bridgeValue }

                    if var bs = bsVal {
                        if var ds = dsVal {
                            return wgpu_bridge_create_render_pipeline(
                                device, desc.shaderModule.handle,
                                vEntry, fEntry,
                                desc.colorFormat.bridgeValue,
                                desc.topology.bridgeValue,
                                desc.frontFace.bridgeValue,
                                desc.cullMode.bridgeValue,
                                layouts, count, &bs, &ds, &pipelinePtr)
                        } else {
                            return wgpu_bridge_create_render_pipeline(
                                device, desc.shaderModule.handle,
                                vEntry, fEntry,
                                desc.colorFormat.bridgeValue,
                                desc.topology.bridgeValue,
                                desc.frontFace.bridgeValue,
                                desc.cullMode.bridgeValue,
                                layouts, count, &bs, nil, &pipelinePtr)
                        }
                    } else {
                        if var ds = dsVal {
                            return wgpu_bridge_create_render_pipeline(
                                device, desc.shaderModule.handle,
                                vEntry, fEntry,
                                desc.colorFormat.bridgeValue,
                                desc.topology.bridgeValue,
                                desc.frontFace.bridgeValue,
                                desc.cullMode.bridgeValue,
                                layouts, count, nil, &ds, &pipelinePtr)
                        } else {
                            return wgpu_bridge_create_render_pipeline(
                                device, desc.shaderModule.handle,
                                vEntry, fEntry,
                                desc.colorFormat.bridgeValue,
                                desc.topology.bridgeValue,
                                desc.frontFace.bridgeValue,
                                desc.cullMode.bridgeValue,
                                layouts, count, nil, nil, &pipelinePtr)
                        }
                    }
                }

                if desc.vertexBuffers.isEmpty {
                    return callCreate(layouts: nil, count: 0)
                }

                var bridgeLayouts: [WGPUBridgeVertexBufferLayout] = []
                var bridgeAttrs: [[WGPUBridgeVertexAttribute]] = []

                for vbl in desc.vertexBuffers {
                    let attrs = vbl.attributes.map {
                        WGPUBridgeVertexAttribute(
                            format: $0.format.bridgeValue,
                            offset: $0.offset,
                            shader_location: $0.shaderLocation
                        )
                    }
                    bridgeAttrs.append(attrs)
                }

                return try bridgeAttrs.withContiguousStorageIfAvailable { _ -> Int32 in
                    for (i, vbl) in desc.vertexBuffers.enumerated() {
                        bridgeAttrs[i].withUnsafeMutableBufferPointer { attrBuf in
                            bridgeLayouts.append(WGPUBridgeVertexBufferLayout(
                                array_stride: vbl.arrayStride,
                                attributes: attrBuf.baseAddress,
                                attribute_count: UInt32(attrBuf.count)
                            ))
                        }
                    }

                    return bridgeLayouts.withUnsafeMutableBufferPointer { layoutBuf in
                        callCreate(layouts: layoutBuf.baseAddress, count: UInt32(layoutBuf.count))
                    }
                } ?? {
                    throw WGPUBackendError.initFailed("vertex buffer layout allocation failed")
                }()
            }
        }

        guard ok == 1, let pipelinePtr else {
            throw WGPUBackendError.initFailed(Self.lastError())
        }
        return GPURenderPipeline(handle: pipelinePtr)
    }

    public func createBuffer(size: UInt64, usage: GPUBufferUsage, mappedAtCreation: Bool = false) throws -> GPUBuffer {
        guard let device else {
            throw WGPUBackendError.initFailed("device not ready")
        }
        var desc = WGPUBridgeBufferDesc(
            size: size,
            usage_flags: usage.rawValue,
            mapped_at_creation: mappedAtCreation ? 1 : 0
        )
        var bufPtr: UnsafeMutableRawPointer?
        let ok = wgpu_bridge_create_buffer(device, &desc, &bufPtr)
        guard ok == 1, let bufPtr else {
            throw WGPUBackendError.initFailed(Self.lastError())
        }
        return GPUBuffer(handle: bufPtr, size: size)
    }

    public func writeBuffer(_ buffer: GPUBuffer, data: UnsafeRawPointer, size: Int, offset: UInt64 = 0) {
        guard let queue else { return }
        wgpu_bridge_write_buffer(queue, buffer.handle, offset, data, size)
    }

    public func writeTexture(_ texture: GPUTexture,
                             data: UnsafeRawPointer,
                             dataSize: Int,
                             bytesPerRow: UInt32,
                             rowsPerImage: UInt32,
                             width: UInt32,
                             height: UInt32,
                             depthOrLayers: UInt32 = 1,
                             mipLevel: UInt32 = 0) {
        guard let queue else { return }
        wgpu_bridge_write_texture(queue, texture.handle, mipLevel,
                                  data, dataSize,
                                  bytesPerRow, rowsPerImage,
                                  width, height, depthOrLayers)
    }

    public func createTexture(width: UInt32, height: UInt32,
                              format: GPUTextureFormat = .bgra8Unorm,
                              usage: GPUTextureUsage = .renderAttachment,
                              mipLevels: UInt32 = 1,
                              depthOrLayers: UInt32 = 1) throws -> GPUTexture {
        guard let device else {
            throw WGPUBackendError.initFailed("device not ready")
        }
        var desc = WGPUBridgeTextureDesc(
            width: width,
            height: height,
            depth_or_layers: depthOrLayers,
            mip_level_count: mipLevels,
            format: format.bridgeValue,
            usage_flags: usage.rawValue
        )
        var texPtr: UnsafeMutableRawPointer?
        let ok = wgpu_bridge_create_texture(device, &desc, &texPtr)
        guard ok == 1, let texPtr else {
            throw WGPUBackendError.initFailed(Self.lastError())
        }
        return GPUTexture(handle: texPtr)
    }

    public func createCommandEncoder() throws -> GPUCommandEncoder {
        guard let device else {
            throw WGPUBackendError.initFailed("device not ready")
        }
        var encPtr: UnsafeMutableRawPointer?
        let ok = wgpu_bridge_create_command_encoder(device, &encPtr)
        guard ok == 1, let encPtr else {
            throw WGPUBackendError.initFailed(Self.lastError())
        }
        return GPUCommandEncoder(handle: encPtr)
    }

    public func submit(_ commandBuffer: GPUCommandBuffer) {
        guard let queue else { return }
        guard let cbHandle = commandBuffer.take() else { return }
        var buf: UnsafeMutableRawPointer? = cbHandle
        wgpu_bridge_queue_submit(queue, &buf, 1)
    }

    public func createSampler(desc: GPUSamplerDescriptor = .init()) throws -> GPUSampler {
        guard let device else {
            throw WGPUBackendError.initFailed("device not ready")
        }
        var sd = WGPUBridgeSamplerDesc(
            address_mode_u: desc.addressModeU.bridgeValue,
            address_mode_v: desc.addressModeV.bridgeValue,
            mag_filter: desc.magFilter.bridgeValue,
            min_filter: desc.minFilter.bridgeValue,
            mipmap_filter: desc.mipmapFilter.bridgeValue
        )
        var ptr: UnsafeMutableRawPointer?
        let ok = wgpu_bridge_create_sampler(device, &sd, &ptr)
        guard ok == 1, let ptr else {
            throw WGPUBackendError.initFailed(Self.lastError())
        }
        return GPUSampler(handle: ptr)
    }

    public func createBindGroupLayout(entries: [GPUBindGroupLayoutEntry]) throws -> GPUBindGroupLayout {
        guard let device else {
            throw WGPUBackendError.initFailed("device not ready")
        }
        var bridgeEntries = entries.map {
            WGPUBridgeBindGroupLayoutEntry(
                binding: $0.binding,
                visibility: $0.visibility.rawValue,
                type: $0.type.bridgeValue
            )
        }
        var ptr: UnsafeMutableRawPointer?
        let ok = bridgeEntries.withUnsafeMutableBufferPointer { buf in
            wgpu_bridge_create_bind_group_layout(device, buf.baseAddress, UInt32(buf.count), &ptr)
        }
        guard ok == 1, let ptr else {
            throw WGPUBackendError.initFailed(Self.lastError())
        }
        return GPUBindGroupLayout(handle: ptr)
    }

    public func createBindGroup(layout: GPUBindGroupLayout, entries: [GPUBindGroupEntry]) throws -> GPUBindGroup {
        guard let device else {
            throw WGPUBackendError.initFailed("device not ready")
        }
        var bridgeEntries = entries.map {
            WGPUBridgeBindGroupEntry(
                binding: $0.binding,
                buffer: $0.buffer?.handle,
                offset: $0.offset,
                size: $0.size,
                sampler: $0.sampler?.handle,
                texture_view: $0.textureView?.handle
            )
        }
        var ptr: UnsafeMutableRawPointer?
        let ok = bridgeEntries.withUnsafeMutableBufferPointer { buf in
            wgpu_bridge_create_bind_group(device, layout.handle, buf.baseAddress, UInt32(buf.count), &ptr)
        }
        guard ok == 1, let ptr else {
            throw WGPUBackendError.initFailed(Self.lastError())
        }
        return GPUBindGroup(handle: ptr)
    }

    public func createPipelineLayout(bindGroupLayouts: [GPUBindGroupLayout]) throws -> GPUPipelineLayout {
        guard let device else {
            throw WGPUBackendError.initFailed("device not ready")
        }
        var handles: [UnsafeMutableRawPointer?] = bindGroupLayouts.map { $0.handle }
        var ptr: UnsafeMutableRawPointer?
        let ok = handles.withUnsafeMutableBufferPointer { buf in
            wgpu_bridge_create_pipeline_layout(device, buf.baseAddress, UInt32(buf.count), &ptr)
        }
        guard ok == 1, let ptr else {
            throw WGPUBackendError.initFailed(Self.lastError())
        }
        return GPUPipelineLayout(handle: ptr)
    }

    public func createComputePipeline(shaderModule: GPUShaderModule,
                                      entryPoint: String = "main",
                                      layout: GPUPipelineLayout? = nil) throws -> GPUComputePipeline {
        guard let device else {
            throw WGPUBackendError.initFailed("device not ready")
        }
        var ptr: UnsafeMutableRawPointer?
        let ok = entryPoint.withCString { entry in
            wgpu_bridge_create_compute_pipeline(device, shaderModule.handle,
                                                entry, layout?.handle, &ptr)
        }
        guard ok == 1, let ptr else {
            throw WGPUBackendError.initFailed(Self.lastError())
        }
        return GPUComputePipeline(handle: ptr)
    }

    public func beginRenderPassMRT(encoder: GPUCommandEncoder,
                                   colorAttachments: [GPUColorAttachment],
                                   depthView: GPUTextureView? = nil,
                                   depthLoadOp: GPULoadOp = .clear,
                                   depthStoreOp: GPUStoreOp = .store,
                                   depthClearValue: Float = 1.0,
                                   stencilLoadOp: GPULoadOp = .clear,
                                   stencilStoreOp: GPUStoreOp = .discard,
                                   stencilClearValue: UInt32 = 0) throws -> GPURenderPassEncoder {
        var bridgeColors = colorAttachments.map {
            WGPUBridgeColorAttachment(
                view: $0.view.handle,
                load_op: $0.loadOp.bridgeValue,
                store_op: $0.storeOp.bridgeValue,
                clear_color: $0.clearColor.bridgeValue
            )
        }

        var depthAttachment: WGPUBridgeDepthStencilAttachment?
        if let depthView {
            depthAttachment = WGPUBridgeDepthStencilAttachment(
                view: depthView.handle,
                depth_load_op: depthLoadOp.bridgeValue,
                depth_store_op: depthStoreOp.bridgeValue,
                clear_depth: depthClearValue,
                stencil_load_op: stencilLoadOp.bridgeValue,
                stencil_store_op: stencilStoreOp.bridgeValue,
                stencil_clear_value: stencilClearValue
            )
        }

        var passPtr: UnsafeMutableRawPointer?
        let ok: Int32
        if var da = depthAttachment {
            ok = bridgeColors.withUnsafeMutableBufferPointer { buf in
                wgpu_bridge_begin_render_pass_mrt(encoder.handle,
                                                  buf.baseAddress, UInt32(buf.count),
                                                  &da, &passPtr)
            }
        } else {
            ok = bridgeColors.withUnsafeMutableBufferPointer { buf in
                wgpu_bridge_begin_render_pass_mrt(encoder.handle,
                                                  buf.baseAddress, UInt32(buf.count),
                                                  nil, &passPtr)
            }
        }

        guard ok == 1, let passPtr else {
            throw WGPUBackendError.initFailed(Self.lastError())
        }
        return GPURenderPassEncoder(handle: passPtr)
    }

    public func createRenderPipelineMRT(
        shaderModule: GPUShaderModule,
        vertexEntryPoint: String = "vs_main",
        fragmentEntryPoint: String = "fs_main",
        colorFormats: [GPUTextureFormat],
        blends: [GPUBlendState]? = nil,
        topology: GPUPrimitiveTopology = .triangleList,
        frontFace: GPUFrontFace = .ccw,
        cullMode: GPUCullMode = .none,
        vertexBuffers: [GPUVertexBufferLayout] = [],
        depthStencil: GPUDepthStencilPipelineState? = nil
    ) throws -> GPURenderPipeline {
        guard let device else {
            throw WGPUBackendError.initFailed("device not ready")
        }
        var formats = colorFormats.map { $0.bridgeValue }
        let bridgeBlends: [WGPUBridgeBlendState]? = blends?.map { $0.bridgeValue }

        var vbLayouts: [WGPUBridgeVertexBufferLayout] = []
        var attrArrays: [[WGPUBridgeVertexAttribute]] = []
        for vbl in vertexBuffers {
            let attrs = vbl.attributes.map {
                WGPUBridgeVertexAttribute(format: $0.format.bridgeValue,
                                          offset: $0.offset,
                                          shader_location: $0.shaderLocation)
            }
            attrArrays.append(attrs)
        }

        var pipelinePtr: UnsafeMutableRawPointer?

        let ok: Int32 = vertexEntryPoint.withCString { vEntry in
            fragmentEntryPoint.withCString { fEntry -> Int32 in
                for (i, vbl) in vertexBuffers.enumerated() {
                    attrArrays[i].withUnsafeMutableBufferPointer { attrBuf in
                        vbLayouts.append(WGPUBridgeVertexBufferLayout(
                            array_stride: vbl.arrayStride,
                            attributes: attrBuf.baseAddress,
                            attribute_count: UInt32(attrBuf.count)
                        ))
                    }
                }

                var dsVal: WGPUBridgeDepthStencilPipelineState?
                if let ds = depthStencil { dsVal = ds.bridgeValue }

                return formats.withUnsafeMutableBufferPointer { fmtBuf in
                    vbLayouts.withUnsafeMutableBufferPointer { vbBuf in
                        if var dsv = dsVal {
                            if var bl = bridgeBlends {
                                return bl.withUnsafeMutableBufferPointer { blBuf in
                                    wgpu_bridge_create_render_pipeline_mrt(
                                        device, shaderModule.handle,
                                        vEntry, fEntry,
                                        fmtBuf.baseAddress, blBuf.baseAddress,
                                        UInt32(fmtBuf.count),
                                        topology.bridgeValue, frontFace.bridgeValue,
                                        cullMode.bridgeValue,
                                        vbBuf.baseAddress, UInt32(vbBuf.count),
                                        &dsv, &pipelinePtr)
                                }
                            } else {
                                return wgpu_bridge_create_render_pipeline_mrt(
                                    device, shaderModule.handle,
                                    vEntry, fEntry,
                                    fmtBuf.baseAddress, nil,
                                    UInt32(fmtBuf.count),
                                    topology.bridgeValue, frontFace.bridgeValue,
                                    cullMode.bridgeValue,
                                    vbBuf.baseAddress, UInt32(vbBuf.count),
                                    &dsv, &pipelinePtr)
                            }
                        } else {
                            if var bl = bridgeBlends {
                                return bl.withUnsafeMutableBufferPointer { blBuf in
                                    wgpu_bridge_create_render_pipeline_mrt(
                                        device, shaderModule.handle,
                                        vEntry, fEntry,
                                        fmtBuf.baseAddress, blBuf.baseAddress,
                                        UInt32(fmtBuf.count),
                                        topology.bridgeValue, frontFace.bridgeValue,
                                        cullMode.bridgeValue,
                                        vbBuf.baseAddress, UInt32(vbBuf.count),
                                        nil, &pipelinePtr)
                                }
                            } else {
                                return wgpu_bridge_create_render_pipeline_mrt(
                                    device, shaderModule.handle,
                                    vEntry, fEntry,
                                    fmtBuf.baseAddress, nil,
                                    UInt32(fmtBuf.count),
                                    topology.bridgeValue, frontFace.bridgeValue,
                                    cullMode.bridgeValue,
                                    vbBuf.baseAddress, UInt32(vbBuf.count),
                                    nil, &pipelinePtr)
                            }
                        }
                    }
                }
            }
        }

        guard ok == 1, let pipelinePtr else {
            throw WGPUBackendError.initFailed(Self.lastError())
        }
        return GPURenderPipeline(handle: pipelinePtr)
    }

    public func bufferMapSync(_ buffer: GPUBuffer, offset: UInt64 = 0, size: UInt64 = 0) throws {
        guard let device else {
            throw WGPUBackendError.initFailed("device not ready")
        }
        let sz = size > 0 ? size : buffer.size
        let ok = wgpu_bridge_buffer_map_sync(device, buffer.handle, offset, sz)
        guard ok == 1 else {
            throw WGPUBackendError.initFailed(Self.lastError())
        }
    }

    // MARK: - Render Bundles

    public func createRenderBundleEncoder(_ desc: GPURenderBundleEncoderDescriptor) throws -> GPURenderBundleEncoder {
        guard let device else {
            throw WGPUBackendError.initFailed("device not ready")
        }
        let formats = desc.colorFormats.map { $0.bridgeValue }
        var out: UnsafeMutableRawPointer?
        let ok = formats.withUnsafeBufferPointer { buf -> Int32 in
            var d = WGPUBridgeRenderBundleEncoderDesc(
                color_formats: buf.baseAddress,
                color_format_count: UInt32(buf.count),
                has_depth_stencil: desc.depthStencilFormat != nil ? 1 : 0,
                depth_stencil_format: desc.depthStencilFormat?.bridgeValue ?? WGPUBridge_TextureFormat_Depth32Float,
                sample_count: desc.sampleCount,
                depth_read_only: desc.depthReadOnly ? 1 : 0,
                stencil_read_only: desc.stencilReadOnly ? 1 : 0
            )
            return wgpu_bridge_create_render_bundle_encoder(device, &d, &out)
        }
        guard ok != 0, let h = out else {
            throw RHIError.bundleEncoderCreationFailed
        }
        return GPURenderBundleEncoder(handle: h)
    }

    // MARK: - Async Pipeline Creation
    //
    // wgpu-native v22 公开了 wgpuDeviceCreateRenderPipelineAsync，但完整集成需要复制
    // 全部描述符构建逻辑。当前以 Swift 层 Task.detached 封装作为务实方案：
    // 调用线程不阻塞，shader 编译在后台线程执行。
    // 待后续若启用真正 async，仅需把此处的实现替换为 callback-based withCheckedThrowingContinuation。

    public func createRenderPipelineAsync(_ desc: GPURenderPipelineDescriptor) async throws -> GPURenderPipeline {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GPURenderPipeline, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let p = try self.createRenderPipeline(desc: desc)
                    cont.resume(returning: p)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func createComputePipelineAsync(shaderModule: GPUShaderModule,
                                           entryPoint: String = "main",
                                           layout: GPUPipelineLayout? = nil) async throws -> GPUComputePipeline {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GPUComputePipeline, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    cont.resume(throwing: RHIError.asyncPipelineFailed)
                    return
                }
                do {
                    let p = try self.createComputePipeline(
                        shaderModule: shaderModule,
                        entryPoint: entryPoint,
                        layout: layout
                    )
                    cont.resume(returning: p)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

extension WGPUBackend: @unchecked Sendable {}
