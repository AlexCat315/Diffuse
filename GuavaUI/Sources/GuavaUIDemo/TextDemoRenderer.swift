#if canImport(Metal) && canImport(QuartzCore)
import Metal
import QuartzCore
import PlatformShell

/// Minimal Metal renderer that blits an alpha framebuffer to a CAMetalLayer.
/// Used for the text demo; will be replaced by DrawListRenderer in Phase 5.
@MainActor
final class TextDemoRenderer {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var texture: MTLTexture?
    private var layerConfigured = false

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        let shaderSrc = """
        #include <metal_stdlib>
        using namespace metal;

        struct V2F {
            float4 pos [[position]];
            float2 uv;
        };

        vertex V2F vs(uint vid [[vertex_id]]) {
            constexpr float2 verts[4] = { {0,0}, {1,0}, {0,1}, {1,1} };
            V2F out;
            float2 v = verts[vid];
            out.pos = float4(v * 2.0 - 1.0, 0.0, 1.0);
            out.pos.y = -out.pos.y;
            out.uv = v;
            return out;
        }

        fragment float4 fs(V2F in [[stage_in]],
                           texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(filter::nearest);
            float a = tex.sample(s, in.uv).r;
            return float4(0.92, 0.92, 0.92, 1.0) * a + float4(0.15, 0.15, 0.18, 1.0) * (1.0 - a);
        }
        """

        do {
            let lib = try device.makeLibrary(source: shaderSrc, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "vs")
            desc.fragmentFunction = lib.makeFunction(name: "fs")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("Metal pipeline creation failed: \(error)")
            return nil
        }
    }

    /// Upload a single-channel alpha framebuffer.
    func uploadFramebuffer(_ data: [UInt8], width: Int, height: Int) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        tex.replace(
            region: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: width
        )
        self.texture = tex
    }

    /// Render the uploaded framebuffer to the given native surface.
    func render(surface: NativeRenderSurface) {
        guard let texture = texture else { return }
        guard case .metalLayer(let ptr) = surface else { return }
        let layer = Unmanaged<CAMetalLayer>.fromOpaque(ptr).takeUnretainedValue()

        if !layerConfigured {
            layer.device = device
            layer.pixelFormat = .bgra8Unorm
            layerConfigured = true
        }

        guard let drawable = layer.nextDrawable() else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1)
        passDesc.colorAttachments[0].storeAction = .store

        guard let cmdBuf = queue.makeCommandBuffer(),
              let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        enc.setRenderPipelineState(pipelineState)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
#endif
