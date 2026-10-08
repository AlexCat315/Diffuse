import NativeRHI

/// An immutable compute program. Bindings are owned by the recording frame.
final class NativeComputePass {
    private let device: Device
    private let bindings: BindingLayout
    private let pipeline: ComputePipeline
    init(device: Device, shader: String, bufferStrides: [UInt32: Int] = [:]) throws {
        self.device = device
        let artifact = try NativeShaderLibrary.artifact(name: shader,api: device.backendAPI,stage: .compute)
        for (slot,stride) in bufferStrides {
            guard artifact.interface.bindings.first(where: { $0.slot == slot })?.buffer.elementStride == stride else {
                throw RHIError.layoutMismatch("\(shader) buffer \(slot) shader/host stride differs")
            }
        }
        bindings = try device.makeBindingLayout(NativeShaderLibrary.layout(artifacts: [artifact]))
        let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [bindings]))
        let module = try device.makeShaderModule(artifact.moduleDescriptor()); defer { device.destroy(module) }
        pipeline = try device.makeComputePipeline(ComputePipelineDescriptor(layout: layout,shader: module,label: "native-\(shader)"))
    }
    deinit { device.destroy(pipeline) }
    func encode(entries: [BindingSetEntry], groups: Int, into commands: CommandBuffer) throws {
        let set = try device.makeBindingSet(layout: bindings,descriptor: BindingSetDescriptor(entries: entries))
        commands.computePass {
            $0.setPipeline(pipeline); $0.setBindingSet(set); $0.dispatch(groupsX: groups)
        }
    }
}
