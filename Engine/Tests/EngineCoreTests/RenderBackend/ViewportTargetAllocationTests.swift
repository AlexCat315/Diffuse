import Testing
@testable import RenderBackend

@Suite("ViewportTargetAllocation")
struct ViewportTargetAllocationTests {
    @Test("quantizes up to the allocation granularity")
    func quantizesUp() {
        #expect(ViewportTargetAllocation.quantized(1) == 256)
        #expect(ViewportTargetAllocation.quantized(255) == 256)
        #expect(ViewportTargetAllocation.quantized(256) == 256)
        #expect(ViewportTargetAllocation.quantized(257) == 512)
        #expect(ViewportTargetAllocation.quantized(0) == 256)
        #expect(ViewportTargetAllocation.quantized(UInt32.max) == ViewportTargetAllocation.maxDimension)
    }

    @Test("reuses the current capacity while it fits")
    func reusesCapacity() {
        let current = RenderDrawableSize(width: 1536, height: 1024)
        // Shrinks and equal sizes keep the allocation.
        #expect(ViewportTargetAllocation.grownCapacity(
            current: current, used: RenderDrawableSize(width: 800, height: 600)) == current)
        #expect(ViewportTargetAllocation.grownCapacity(
            current: current, used: current) == current)
        // Growth in either axis reallocates, quantized, never shrinking the other axis.
        let grownW = ViewportTargetAllocation.grownCapacity(
            current: current, used: RenderDrawableSize(width: 1600, height: 600))
        #expect(grownW == RenderDrawableSize(width: 1792, height: 1024))
        let grownH = ViewportTargetAllocation.grownCapacity(
            current: current, used: RenderDrawableSize(width: 100, height: 1100))
        #expect(grownH == RenderDrawableSize(width: 1536, height: 1280))
    }

    @Test("initial allocation starts from the quantized used size")
    func initialAllocation() {
        let grown = ViewportTargetAllocation.grownCapacity(
            current: RenderDrawableSize(width: 0, height: 0),
            used: RenderDrawableSize(width: 1400, height: 800))
        #expect(grown == RenderDrawableSize(width: 1536, height: 1024))
    }

    @Test("clamps the used extent to hardware-safe bounds")
    func clampsUsed() {
        #expect(ViewportTargetAllocation.clampedUsed(RenderDrawableSize(width: 0, height: 0))
                == RenderDrawableSize(width: 1, height: 1))
        #expect(ViewportTargetAllocation.clampedUsed(RenderDrawableSize(width: UInt32.max, height: 4))
                == RenderDrawableSize(width: ViewportTargetAllocation.maxDimension, height: 4))
    }

    @Test("fullscreen post shaders sample through the PostFrame sub-region uniforms")
    func postShadersCarrySubRegionUniforms() throws {
        let catalog = try ShaderCatalog()
        for name in ["tonemap", "fxaa", "bloom", "taa", "ssao", "ssr", "ink_paper_post"] {
            let source = try catalog.loadWGSLRenderModule(named: name)
            #expect(source.contains("var<uniform> frame_u : PostFrame"), "\(name) missing PostFrame uniform")
            #expect(source.contains("frame_u.uv_scale"), "\(name) not scaling sample UVs")
            // Regression: ssao/ssr previously referenced a nonexistent
            // `u.resolution` member, which fails WGSL validation.
            #expect(!source.contains("u.resolution;"), "\(name) references stale u.resolution")
        }
    }
}
