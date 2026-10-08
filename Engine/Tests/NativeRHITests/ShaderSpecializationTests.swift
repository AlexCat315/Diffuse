import Foundation
import NativeRHI
import XCTest

final class ShaderSpecializationTests: XCTestCase {
    func testSpecializedDimensionsAndTypesValidate() throws {
        var artifact = ShaderArtifact(stage: .compute,format: .mslSource,entryPoint: "main",code: Data([1]),compiler: "test")
        artifact.interface.threadgroupSize = ThreadgroupSize(x: 64)
        artifact.interface.specializationConstants = [ReflectedShaderConstant(id: 0,name: "localSize",type: .uint32)]
        artifact.interface.threadgroupSpecialization = ThreadgroupSpecialization(x: 0)
        XCTAssertEqual(try artifact.moduleDescriptor().threadgroupSize,ThreadgroupSize(x: 64))
        XCTAssertEqual(try artifact.moduleDescriptor().specializationConstants,[.init(id: 0,value: .uint32(64))])
        XCTAssertEqual(try artifact.moduleDescriptor(specialization: [.init(id: 0,value: .uint32(37))]).threadgroupSize,ThreadgroupSize(x: 37))
        for constants: [ShaderSpecializationConstant] in [
            [.init(id: 0,value: .uint32(0))],[.init(id: 1,value: .uint32(37))],
            [.init(id: 0,value: .float32(37))],[.init(id: 0,value: .uint32(37)),.init(id: 0,value: .uint32(37))]
        ] { XCTAssertThrowsError(try artifact.moduleDescriptor(specialization: constants)) }
        let roundTrip = try JSONDecoder().decode(ShaderArtifact.self,from: JSONEncoder().encode(artifact))
        XCTAssertEqual(try roundTrip.moduleDescriptor(specialization: [.init(id: 0,value: .uint32(255))]).threadgroupSize.x,255)
    }
    #if os(macOS)
    func testMetalPhysicalGroupsAndTypedFunctionConstants() throws { try run(.metal) }
    #endif
    #if os(Windows) || os(Linux)
    func testVulkanPhysicalGroupsAndTypedSpecialization() throws { try run(.vulkan) }
    #endif
    private func run(_ api: GraphicsAPI) throws {
        let artifact = try ShaderFixtures.compile("specialization",entry: "specializedCompute",stage: .compute,
            target: api == .metal ? "metal" : "spirv",groups: [37,1,1],groupConstants: [0,-1,-1])
        let device = try Device.make(DeviceConfig(preferredBackends: [api],enableValidation: false))
        for (size,enabled) in [(1,true),(37,true),(64,false),(255,true),(256,true)] {
            var constants: [ShaderSpecializationConstant] = [.init(id: 1,value: .int32(-3)),
                .init(id: 2,value: .float32(0.5)),.init(id: 3,value: .bool(enabled))]
            if size != 37 { constants.append(.init(id: 0,value: .uint32(UInt32(size)))) }
            let descriptor = try artifact.moduleDescriptor(specialization: constants)
            let module = try device.makeShaderModule(descriptor); defer { device.destroy(module) }
            let binding = try device.makeBindingLayout(artifact.bindingLayoutDescriptor())
            let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [binding]))
            let pipeline = try device.makeComputePipeline(ComputePipelineDescriptor(layout: layout,shader: module)); defer { device.destroy(pipeline) }
            let count = size*3
            let buffer = try device.makeBuffer(BufferDescriptor(size: count*4,usage: [.storageWrite,.transferSource])); defer { device.destroy(buffer) }
            let set = try device.makeBindingSet(layout: binding,descriptor: BindingSetDescriptor(entries: [.init(slot: 0,resource: .storageBuffer(buffer: buffer))]))
            let commands = CommandBuffer()
            commands.computePass { $0.setPipeline(pipeline); $0.setBindingSet(set); $0.dispatch(groupsX: 3) }
            try device.beginFrame(); try device.submit(commands); device.endFrame()
            var values = [Float](repeating: 0,count: count)
            try values.withUnsafeMutableBytes { try device.readBufferData(buffer,into: $0) }
            var middle: Float = 0
            try withUnsafeMutableBytes(of: &middle) { try device.readBufferData(buffer,offset: 4,into: $0) }
            XCTAssertEqual(middle,values[1])
            try withUnsafeMutableBytes(of: &middle) { bytes in
                XCTAssertThrowsError(try device.readBufferData(buffer,offset: -1,into: bytes))
                XCTAssertThrowsError(try device.readBufferData(buffer,offset: count*4,into: bytes))
            }
            for (index,value) in values.enumerated() {
                XCTAssertEqual(value,enabled ? (Float(index)-3)*0.5+Float(size)*0.01 : -1,accuracy: 0.0001)
            }
        }
    }
}
