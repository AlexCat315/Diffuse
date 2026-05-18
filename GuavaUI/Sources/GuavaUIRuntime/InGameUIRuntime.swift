import EngineKernel
import Foundation
import RHIWGPU

/// Implements `InGameUIProviding` using GuavaUI's `DrawListRenderer`.
///
/// Create one per `WGPUBackend` and register with `InGameUIRegistry.shared.provider`
/// before the first render frame. All methods are called on the render thread.
public final class InGameUIRuntime: InGameUIProviding, @unchecked Sendable {

    private let renderer: DrawListRenderer
    private let fontProvider: FontProvider
    private let atlas: FontAtlas
    private let shaper: TextShaper
    private let drawList = DrawList()

    private let atlasTextureID: TextureID = 1
    private var atlasOnGPU = false
    private var fontLoaded = false
    private var configuredFormat: GPUTextureFormat?

    public init(backend: WGPUBackend) {
        self.renderer = DrawListRenderer(backend: backend)
        self.fontProvider = FontProvider(size: 16, rasterScale: 2)
        self.atlas = FontAtlas(width: 512, height: 512)
        self.shaper = TextShaper()
    }

    // MARK: - InGameUIProviding

    public func renderInGameUI(
        canvas: InGameCanvas,
        commandEncoder: AnyObject,
        colorView: AnyObject,
        formatHint: String,
        width: Int,
        height: Int,
        deltaTime: Double
    ) {
        guard let encoder = commandEncoder as? GPUCommandEncoder,
              let view = colorView as? GPUTextureView,
              width > 0, height > 0,
              !canvas.commands.isEmpty
        else { return }

        let gpuFormat: GPUTextureFormat
        switch formatHint {
        case "rgba16Float": gpuFormat = .rgba16Float
        case "rgba8Unorm":  gpuFormat = .rgba8Unorm
        default:            gpuFormat = .bgra8Unorm
        }

        if configuredFormat != gpuFormat {
            try? renderer.configure(format: gpuFormat)
            configuredFormat = gpuFormat
        }
        guard configuredFormat != nil else { return }

        ensureFont()

        drawList.reset()
        drawList.setViewportBounds(UIRect(x: 0, y: 0, width: Float(width), height: Float(height)))
        for command in canvas.commands { translate(command) }
        if drawList.vertices.isEmpty { return }

        uploadAtlasIfNeeded()

        do {
            let pass = try encoder.beginRenderPass(
                colorView: view,
                loadOp: .load,
                storeOp: .store,
                clearColor: .clear
            )
            try renderer.render(
                list: drawList,
                pass: pass,
                viewportPx: (UInt32(width), UInt32(height))
            )
            pass.end()
        } catch {}
    }

    public func notifyResize(width: Int, height: Int) {}

    // MARK: - Font

    private func ensureFont() {
        guard !fontLoaded else { return }
        fontLoaded = true
        let size: Float = 16
        let scale: Float = 2
        guard let managed = fontProvider.loadPrimaryFont(name: ".AppleSystemUIFont") else { return }
        atlas.registerFace(managed.rawFace, fontID: managed.id, size: size, rasterScale: scale)
        shaper.setFont(ftFace: managed.rawFace, size: size, rasterScale: scale)
    }

    private func uploadAtlasIfNeeded() {
        guard atlas.isDirty, let (region, pixels) = atlas.dirtyUploadPayload() else { return }
        pixels.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            if !atlasOnGPU {
                try? renderer.registerAlphaTexture(
                    id: atlasTextureID,
                    pixels: base,
                    width: UInt32(region.width),
                    height: UInt32(region.height),
                    originX: UInt32(region.x),
                    originY: UInt32(region.y),
                    textureWidth: UInt32(atlas.atlasWidth),
                    textureHeight: UInt32(atlas.atlasHeight)
                )
                atlasOnGPU = true
            } else {
                try? renderer.registerAlphaTexture(
                    id: atlasTextureID,
                    pixels: base,
                    width: UInt32(region.width),
                    height: UInt32(region.height),
                    originX: UInt32(region.x),
                    originY: UInt32(region.y),
                    textureWidth: UInt32(atlas.atlasWidth),
                    textureHeight: UInt32(atlas.atlasHeight)
                )
            }
        }
        atlas.markClean()
    }

    // MARK: - Command translation

    private func translate(_ command: InGameCanvasCommand) {
        switch command {
        case let .rect(x, y, w, h, color, cornerRadius):
            let r = UIRect(x: x, y: y, width: w, height: h)
            if cornerRadius > 0 {
                drawList.addRoundedRect(r, radius: cornerRadius, color: uiColor(color))
            } else {
                drawList.addRect(r, color: uiColor(color))
            }

        case let .progressBar(x, y, w, h, value, maxValue, fillColor, bgColor, cornerRadius):
            let bgRect = UIRect(x: x, y: y, width: w, height: h)
            if cornerRadius > 0 {
                drawList.addRoundedRect(bgRect, radius: cornerRadius, color: uiColor(bgColor))
            } else {
                drawList.addRect(bgRect, color: uiColor(bgColor))
            }
            let fraction = maxValue > 0 ? max(0, min(1, value / maxValue)) : 0
            let fw = w * fraction
            if fw > 0 {
                let fillRect = UIRect(x: x, y: y, width: fw, height: h)
                let r = min(cornerRadius, fw * 0.5)
                if r > 0 {
                    drawList.addRoundedRect(fillRect, radius: r, color: uiColor(fillColor))
                } else {
                    drawList.addRect(fillRect, color: uiColor(fillColor))
                }
            }

        case let .label(text, x, y, fontSize, color):
            renderLabel(text: text, x: x, y: y, fontSize: fontSize, color: color)
        }
    }

    private func renderLabel(text: String, x: Float, y: Float, fontSize: Float, color: InGameUIColor) {
        guard fontLoaded, !text.isEmpty else { return }
        let lineHeight = fontSize * 1.25
        let glyphs = shaper.shape(text: text)
        guard !glyphs.isEmpty else { return }
        let layout = TextLayout.layout(
            shapedGlyphs: glyphs,
            text: text,
            atlas: atlas,
            maxWidth: .infinity,
            lineHeight: lineHeight
        )
        guard !layout.lines.isEmpty else { return }
        drawList.addText(
            layout,
            origin: (x: x, y: y + lineHeight),
            color: uiColor(color),
            textureID: atlasTextureID,
            atlas: atlas
        )
    }

    private func uiColor(_ c: InGameUIColor) -> Color {
        Color(r: c.r, g: c.g, b: c.b, a: c.a)
    }
}
