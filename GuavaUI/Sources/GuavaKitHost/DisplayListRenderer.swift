import GuavaKit
import GuavaUIRuntime

// Translates a GuavaKit `DisplayList` (pure data) into the existing
// GuavaUIRuntime `DrawList`, so the new framework reuses the entire wgpu
// rendering pipeline unchanged. This is the whole point of keeping the core
// backend-agnostic: the GPU layer never needs to know GuavaKit exists.
public struct DisplayListRenderer {
    public init() {}

    public func render(_ list: GuavaKit.DisplayList, into draw: DrawList) {
        for command in list.commands {
            switch command {
            case .fillRect(let rect, let color):
                draw.addRect(uiRect(rect), color: uiColor(color))

            case .strokeRect(let rect, let color, let width):
                strokeRect(uiRect(rect), color: uiColor(color), width: width, into: draw)

            case .text:
                // Glyph emission needs the font-atlas bridge (next integration
                // step); the layout/measurement side is already wired via
                // `TextMeasuring`. Skipped here so non-text UI renders today.
                break

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
