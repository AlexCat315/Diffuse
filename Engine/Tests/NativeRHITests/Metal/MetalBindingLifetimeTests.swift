#if canImport(Metal)
import Metal
import XCTest
@testable import NativeRHI

final class MetalBindingLifetimeTests: XCTestCase {
    private func backend() throws -> MetalDevice {
        try XCTUnwrap(MetalDevice.make(config: DeviceConfig(preferredBackends: [.metal])) as? MetalDevice)
    }

    private func bind(_ backend: MetalDevice, id: UInt32, resources: [BindingResource]) throws -> BindingSet {
        let entries = resources.enumerated().map { BindingSetEntry(slot: UInt32($0.offset), resource: $0.element) }
        let layout = BindingLayout(id: id + 10_000)
        let layoutEntries = resources.enumerated().map {
            BindingLayoutEntry(slot: UInt32($0.offset), type: $0.element.tracksAs?.type ?? .sampler,
                visibility: [.graphics, .compute])
        }
        try backend.registerBindingLayout(layout, descriptor: BindingLayoutDescriptor(entries: layoutEntries))
        let set = BindingSet(id: id)
        try backend.registerBindingSet(set, layout: layout, layoutEntries: layoutEntries, setEntries: entries)
        return set
    }

    func testResolvedBindingsPreserveNativeObjectsAndBufferOffsets() throws {
        let backend = try backend()
        let buffer = Buffer(id: 1), texture = Texture(id: 2), sampler = Sampler(id: 3)
        try backend.createBuffer(buffer, descriptor: BufferDescriptor(size: 64, usage: [.uniform, .storageRead]))
        try backend.createTexture(texture, descriptor: TextureDescriptor(width: 1, height: 1, format: .rgba8Unorm,
            usage: [.sampled, .storageRead, .storageWrite]))
        try backend.createSampler(sampler, descriptor: SamplerDescriptor())
        let set = try bind(backend, id: 100, resources: [.uniformBuffer(buffer: buffer, offset: 16, size: 16),
            .storageBuffer(buffer: buffer, offset: 32), .texture(texture), .sampler(sampler)])
        let entries = try XCTUnwrap(backend.registries.bindingSets[set.id]).entries
        XCTAssertEqual(entries.count, 4)
        for (index, offset) in [(0, 16), (1, 32)] {
            guard case .buffer(let native, let actual) = entries[index].resource.value else { return XCTFail("expected buffer") }
            XCTAssertTrue(native === backend.registries.buffers[buffer.id])
            XCTAssertEqual(actual, offset)
        }
        guard case .texture(let nativeTexture) = entries[2].resource.value,
              case .sampler(let nativeSampler) = entries[3].resource.value else { return XCTFail("expected texture/sampler") }
        XCTAssertTrue(nativeTexture === backend.registries.textures[texture.id])
        XCTAssertTrue(nativeSampler === backend.registries.samplers[sampler.id])
        XCTAssertThrowsError(try bind(backend, id: set.id, resources: [.uniformBuffer(buffer: buffer, offset: 60, size: 16)]))
        XCTAssertEqual(backend.registries.bindingSets[set.id]?.entries.count, 4, "failed replacement must keep the valid set")
    }

    func testUnregisterReplacementAndRetirementReleaseOnlyDependentSets() throws {
        let backend = try backend()
        let first = Buffer(id: 1), second = Buffer(id: 2), sampler = Sampler(id: 3)
        weak var firstNative: MTLBuffer?
        try autoreleasepool {
            try backend.createBuffer(first, descriptor: BufferDescriptor(size: 16, usage: .uniform))
            try backend.createBuffer(second, descriptor: BufferDescriptor(size: 16, usage: .uniform))
            try backend.createSampler(sampler, descriptor: SamplerDescriptor())
            firstNative = backend.registries.buffers[first.id]
            _ = try bind(backend, id: 100, resources: [.uniformBuffer(buffer: first), .sampler(sampler)])
            _ = try bind(backend, id: 101, resources: [.uniformBuffer(buffer: first)])
            _ = try bind(backend, id: 102, resources: [.sampler(sampler)])
        }
        XCTAssertNotNil(firstNative)
        backend.unregisterBindingSet(BindingSet(id: 100))
        _ = try bind(backend, id: 100, resources: [.uniformBuffer(buffer: second)])
        autoreleasepool { backend.destroyBuffer(first) }
        XCTAssertNil(firstNative, "retired resources must not remain retained by cached sets")
        XCTAssertNil(backend.registries.bindingSets[101])
        XCTAssertNotNil(backend.registries.bindingSets[100], "replacement no longer uses the retired resource")
        XCTAssertNotNil(backend.registries.bindingSets[102])
        backend.destroySampler(sampler)
        XCTAssertNil(backend.registries.bindingSets[102])
        XCTAssertNotNil(backend.registries.bindingSets[100])
        backend.destroyBuffer(second)
        XCTAssertNil(backend.registries.bindingSets[100])
        XCTAssertThrowsError(try bind(backend, id: 103, resources: [.uniformBuffer(buffer: first)]))
        let submit = PlannedSubmit(queue: .graphics, commands: [
            .computePass(ComputePassRecord(body: [.setBindingSet(slot: 0, set: BindingSet(id: 100))]))])
        var completed = false
        XCTAssertThrowsError(try backend.submit(submit) { completed = true }) { error in
            guard case RHIError.invalidArgument(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(reason, "unknown compute binding set")
        }
        XCTAssertFalse(completed, "invalidated bindings must be rejected before any work is queued")
    }

    func testTextureRetirementAndShaderUsageValidation() throws {
        let backend = try backend()
        let sampled = Texture(id: 1), attachment = Texture(id: 2)
        weak var native: MTLTexture?
        try autoreleasepool {
            try backend.createTexture(sampled, descriptor: TextureDescriptor(width: 1, height: 1, format: .rgba8Unorm,
                usage: [.sampled, .storageRead, .storageWrite]))
            try backend.createTexture(attachment, descriptor: TextureDescriptor(width: 1, height: 1, format: .rgba8Unorm,
                usage: .colorTarget))
            native = backend.registries.textures[sampled.id]
            _ = try bind(backend, id: 100, resources: [.texture(sampled)])
            _ = try bind(backend, id: 101, resources: [.storageTexture(sampled)])
        }
        XCTAssertThrowsError(try bind(backend, id: 102, resources: [.texture(attachment)]))
        XCTAssertThrowsError(try bind(backend, id: 103, resources: [.storageTexture(attachment)]))
        autoreleasepool { backend.destroyTexture(sampled) }
        XCTAssertNil(native)
        XCTAssertNil(backend.registries.bindingSets[100])
        XCTAssertNil(backend.registries.bindingSets[101])
        XCTAssertNotNil(backend.registries.textures[attachment.id])
    }
}
#endif
