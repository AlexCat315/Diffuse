import Foundation
import XCTest
import NativeRHI

final class ReflectedBindingLayoutTests: XCTestCase {
    private func artifact(_ stage: ShaderStage, _ bindings: [ReflectedShaderBinding]) -> ShaderArtifact {
        var artifact = ShaderArtifact(stage: stage, format: .mslSource, entryPoint: "main", code: Data([1]), compiler: "test")
        artifact.interface.bindings = bindings
        return artifact
    }

    func testStageMergePreservesBufferABIAndSortsSlots() throws {
        var uniform = ReflectedShaderBinding(name: "uniform", slot: 0, type: .uniformBuffer)
        uniform.buffer.readOnly = true; uniform.buffer.elementStride = 16
        let texture = ReflectedShaderBinding(name: "image", slot: 1, type: .texture)
        let sampler = ReflectedShaderBinding(name: "sampler", slot: 2, type: .sampler)
        let layout = try BindingLayoutDescriptor(reflecting: [artifact(.vertex, [uniform]), artifact(.fragment, [sampler, texture, uniform])])
        XCTAssertEqual(layout.entries.map(\.slot), [0, 1, 2])
        XCTAssertEqual(layout.entries[0].buffer, uniform.buffer)
        XCTAssertEqual(layout.entries[0].visibility, .graphics)
        XCTAssertEqual(layout.entries[1].visibility, .fragment)
    }

    func testConflictingResourcesSpacesAndDuplicateSlotsAreRejected() throws {
        let original = ReflectedShaderBinding(name: "uniform", slot: 0, type: .uniformBuffer)
        for change in 0..<4 {
            var changed = original
            switch change {
            case 0: changed.type = .storageBuffer
            case 1: changed.buffer.elementStride = 16
            case 2: changed.buffer.readOnly = true
            default: changed.space = 1
            }
            XCTAssertThrowsError(try BindingLayoutDescriptor(reflecting: [artifact(.vertex, [original]), artifact(.fragment, [changed])]))
        }
        XCTAssertThrowsError(try BindingLayoutDescriptor(reflecting: [artifact(.vertex, [original, original])]))
    }
}
