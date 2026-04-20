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
                if desc.vertexBuffers.isEmpty {
                    return wgpu_bridge_create_render_pipeline(
                        device,
                        desc.shaderModule.handle,
                        vEntry, fEntry,
                        desc.colorFormat.bridgeValue,
                        desc.topology.bridgeValue,
                        desc.cullMode.bridgeValue,
                        nil, 0,
                        &pipelinePtr
                    )
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
                        wgpu_bridge_create_render_pipeline(
                            device,
                            desc.shaderModule.handle,
                            vEntry, fEntry,
                            desc.colorFormat.bridgeValue,
                            desc.topology.bridgeValue,
                            desc.cullMode.bridgeValue,
                            layoutBuf.baseAddress,
                            UInt32(layoutBuf.count),
                            &pipelinePtr
                        )
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
}
