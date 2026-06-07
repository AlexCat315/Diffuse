import GuavaKit
import GuavaUIRuntime

/// Translates a GuavaKit `DisplayList` (pure data) into the existing
/// GuavaUIRuntime `DrawList`, so the new framework reuses the entire wgpu
/// rendering pipeline unchanged. Text rendering is handled via a pluggable
/// `FontBridge` that connects GuavaKit's backend-agnostic `.text` commands to
/// the full shape → layout → rasterize → glyph-quad pipeline.
public struct DisplayListRenderer {
    private let textRenderer: TextRenderer?

    /// Creates a solid-shapes-only renderer. `.text` commands are skipped.
    public init() {
        self.textRenderer = nil
    }

    /// Creates a renderer with text support via a `FontBridge`.
    ///
    /// - Parameters:
    ///   - fontBridge: Configured and loaded with at least one font face.
    ///   - atlasTextureID: GPU-side texture ID the renderer registers the
    ///     atlas bitmap under. Must match the ID used by the wgpu pipeline.
    public init(fontBridge: FontBridge, atlasTextureID: TextureID) {
        self.textRenderer = TextRenderer(bridge: fontBridge, textureID: atlasTextureID)
    }

    public func render(_ list: GuavaKit.DisplayList, into draw: DrawList) {
        for command in list.commands {
            switch command {
            case .fillRect(let rect, let color):
                draw.addRect(uiRect(rect), color: uiColor(color))

            case .fillRoundedRect(let rect, let color, let radius):
                draw.addRoundedRect(uiRect(rect), radius: radius, color: uiColor(color))

            case .strokeRect(let rect, let color, let width):
                strokeRect(uiRect(rect), color: uiColor(color), width: width, into: draw)

            case .text(let string, let rect, let color, let size, let lineLimit):
                if let tr = textRenderer {
                    tr.render(text: string, rect: rect, color: uiColor(color), size: size,
                              lineLimit: lineLimit, into: draw)
                }

            case .pushClip(let rect):
                draw.pushClip(uiRect(rect))

            case .popClip:
                draw.popClip()
            }
        }
    }

    private func uiRect(_ r: GuavaKit.Rect) -> UIRect {
        UIRect(x: r.minX, y: r.minY, width: r.size.width, height: r.size.height)
    }
    private func uiColor(_ c: GuavaKit.Color) -> RuntimeColor {
        RuntimeColor(r: c.r, g: c.g, b: c.b, a: c.a)
    }

    /// A border as four thin filled edges (avoids depending on line geometry).
    private func strokeRect(_ r: UIRect, color: RuntimeColor, width: Float, into draw: DrawList) {
        let w = width
        draw.addRect(UIRect(x: r.minX, y: r.minY, width: r.width, height: w), color: color)            // top
        draw.addRect(UIRect(x: r.minX, y: r.maxY - w, width: r.width, height: w), color: color)        // bottom
        draw.addRect(UIRect(x: r.minX, y: r.minY, width: w, height: r.height), color: color)           // left
        draw.addRect(UIRect(x: r.maxX - w, y: r.minY, width: w, height: r.height), color: color)       // right
    }
}

// MARK: - Text renderer (private bridge adapter)

private struct TextRenderer {
    let bridge: FontBridge
    let textureID: TextureID

    func render(
        text: String, rect: GuavaKit.Rect, color: RuntimeColor, size: Float,
        lineLimit: Int?,
        into draw: DrawList
    ) {
        // The rect's width is the max width for line wrapping; the rect's
        // origin is the top-left where text should start.
        let maxWidth = rect.size.width > 0 ? rect.size.width : Float.infinity
        let origin = (x: rect.minX, y: rect.minY)
        // TODO: pass lineLimit through to FontBridge.layout when it supports it.
        bridge.render(
            text: text,
            maxWidth: maxWidth,
            color: color,
            origin: origin,
            textureID: textureID,
            into: draw
        )
    }
}
