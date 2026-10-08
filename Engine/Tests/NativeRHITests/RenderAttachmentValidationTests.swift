import XCTest
@testable import NativeRHI

final class RenderAttachmentValidationTests: XCTestCase {
    private func info(samples: Int = 4, format: TextureFormat = .rgba8Unorm,
        extent: SIMD2<Int> = SIMD2(32, 24), usage: TextureUsage = .colorTarget,
        singleLayer: Bool = true) -> RenderTextureInfo<TextureFormat> {
        RenderTextureInfo(extent: extent, sampleCount: samples, format: format,
                          usage: usage, singleLayer2D: singleLayer, isDepth: format.isDepth)
    }

    func testResolveAndPipelineSignature() throws {
        var color = RenderColorTarget(texture: Texture(id: 1), store: false)
        color.resolveTexture = Texture(id: 2)
        let pass = RenderPassDescriptor(colorTargets: [color], depthTarget: RenderDepthTarget(texture: Texture(id: 3)))
        let resources = [UInt32(1): info(), 2: info(samples: 1), 3: info(format: .depth32Float, usage: .depthStencilTarget)]
        let signature = try rhiRenderPassSignature(pass) { try XCTUnwrap(resources[$0.id]) }
        XCTAssertEqual(signature.extent, SIMD2(32, 24))
        try signature.validate(colors: [.rgba8Unorm], depth: .depth32Float, samples: 4)
        XCTAssertThrowsError(try signature.validate(colors: [.rgba8Unorm], depth: .depth32Float, samples: 1))
        XCTAssertThrowsError(try signature.validate(colors: [.bgra8Unorm], depth: .depth32Float, samples: 4))
        XCTAssertThrowsError(try signature.validate(colors: [.rgba8Unorm], depth: nil, samples: 4))
    }

    func testResolveRejectsShapeFormatUsageSamplesAndAliasing() throws {
        var target = RenderColorTarget(texture: Texture(id: 1)); target.resolveTexture = Texture(id: 2)
        let pass = RenderPassDescriptor(colorTargets: [target])
        for resolve in [info(samples: 4), info(samples: 1, format: .bgra8Unorm),
                        info(samples: 1, extent: SIMD2(33, 24)), info(samples: 1, usage: .sampled),
                        info(samples: 1, singleLayer: false)] {
            XCTAssertThrowsError(try rhiRenderPassSignature(pass) { $0.id == 1 ? self.info() : resolve })
        }
        XCTAssertThrowsError(try rhiRenderPassSignature(pass) { _ in self.info(samples: 1) })
        var integer = info(format: .r32Uint); integer.supportsColorResolve = false
        XCTAssertThrowsError(try rhiRenderPassSignature(pass) {
            $0.id == 1 ? integer : self.info(samples: 1, format: .r32Uint)
        })
        target.resolveTexture = target.texture
        XCTAssertThrowsError(try rhiRenderPassSignature(RenderPassDescriptor(colorTargets: [target])) { _ in self.info() })
        target.resolveTexture = Texture(id: 2)
        XCTAssertThrowsError(try rhiRenderPassSignature(RenderPassDescriptor(colorTargets: [target,
            RenderColorTarget(texture: Texture(id: 2))])) { _ in self.info() })
    }

    func testAttachmentsRejectMismatchedDepthAndDuplicateSources() throws {
        let color = RenderColorTarget(texture: Texture(id: 1))
        let depth = RenderDepthTarget(texture: Texture(id: 2))
        let pass = RenderPassDescriptor(colorTargets: [color], depthTarget: depth)
        for invalid in [info(samples: 1, format: .depth32Float, usage: .depthStencilTarget),
                        info(format: .depth32Float, extent: SIMD2(32, 25), usage: .depthStencilTarget),
                        info(usage: .depthStencilTarget), info(format: .depth32Float, usage: .sampled)] {
            XCTAssertThrowsError(try rhiRenderPassSignature(pass) { $0.id == 1 ? self.info() : invalid })
        }
        XCTAssertThrowsError(try rhiRenderPassSignature(RenderPassDescriptor(colorTargets: [color, color])) { _ in self.info() })
        XCTAssertThrowsError(try rhiRenderPassSignature(RenderPassDescriptor(colorTargets: [])) { _ in self.info() })
    }

    func testMultisampleDescriptorDefaultsAndRestrictions() throws {
        var descriptor = TextureDescriptor(width: 32, height: 24, format: .rgba8Unorm, usage: .colorTarget)
        XCTAssertEqual(descriptor.sampleCount, 1)
        XCTAssertEqual(GraphicsPipelineDescriptor(layout: .init(id: 1), vertex: .init(id: 2)).sampleCount, 1)
        XCTAssertNil(RenderColorTarget(texture: .init(id: 1)).resolveTexture)
        for samples in [1, 2, 4, 8, 16, 32, 64] { descriptor.sampleCount = samples; try rhiValidateTextureSamples(descriptor) }
        for samples in [0, -1, 3, 128, Int.max] {
            descriptor.sampleCount = samples; XCTAssertThrowsError(try rhiValidateTextureSamples(descriptor))
        }
        descriptor.sampleCount = 4
        var array = descriptor; array.dimension = .texture2DArray; array.layers = 2
        var mips = descriptor; mips.mipLevels = 2
        var volume = descriptor; volume.dimension = .texture3D; volume.depth = 2
        for invalid in [array, mips, volume] { XCTAssertThrowsError(try rhiValidateTextureSamples(invalid)) }
        for usage in [TextureUsage.sampled, .storageRead, .storageWrite, .present, .transferSource] {
            var invalid = descriptor; invalid.usage = usage
            XCTAssertThrowsError(try rhiValidateTextureSamples(invalid))
        }
    }
}
