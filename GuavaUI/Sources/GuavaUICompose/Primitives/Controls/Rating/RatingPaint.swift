import Foundation
import GuavaUIRuntime

struct RatingPalette: Equatable {
    let filled: Color
    let empty: Color
    let focus: Color
    init(appearance: RatingAppearance, selection: RatingSelection, theme: Theme) {
        let alpha: Float = selection.isEnabled ? 1 : 0.4
        filled = appearance.filled.resolve(theme).multipliedAlpha(alpha)
        empty = appearance.empty.resolve(theme).multipliedAlpha(alpha)
        focus = theme.colors.focusRing
    }
}

/// SVG rasters retain their size/density cache while preview changes only clipping.
final class RatingPaint {
    private var filled: VectorImageRaster?
    private var outline: VectorImageRaster?
    init(size: Float) {
        func raster(_ resource: BundleImageResource) -> VectorImageRaster? {
            guard let url = resource.url else { return nil }
            return VectorImageRaster(url: url, initial: Image.resolve(path: url.path, width: size, height: size), width: size, height: size)
        }
        filled = raster(UIIcons.Status.starFill); outline = raster(UIIcons.Status.star)
    }
    func draw(value: Double, geometry: RatingGeometry, palette: RatingPalette, node: Node, origin: CGPoint, list: DrawList) {
        let alpha = node.opacity
        let width = Float(node.frame.width), height = Float(node.frame.height)
        guard width > 0, height > 0 else { return }
        let bounds = UIRect(x: Float(origin.x), y: Float(origin.y), width: width, height: height)
        let rtl = geometry.isRTL(node)
        list.pushClip(bounds); defer { list.popClip() }
        for index in 0..<geometry.maximum {
            let rect = geometry.starRect(index, origin: origin, height: height, rtl: rtl)
            if let asset = outline?.resolve(width: geometry.starSize, height: geometry.starSize) {
                asset.retain(in: list)
                list.addImageMaskQuad(rect: rect, textureID: asset.textureID, tint: palette.empty.multipliedAlpha(alpha))
            }
            let fraction = Float(max(0, min(1, value - Double(index))))
            if fraction > 0, let asset = filled?.resolve(width: geometry.starSize, height: geometry.starSize) {
                asset.retain(in: list)
                if fraction < 1 {
                    let filledWidth = rect.width * fraction
                    let clipX = rtl ? rect.x + rect.width - filledWidth : rect.x
                    list.pushClip(UIRect(x: clipX, y: rect.y, width: filledWidth, height: rect.height))
                }
                list.addImageMaskQuad(rect: rect, textureID: asset.textureID, tint: palette.filled.multipliedAlpha(alpha))
                if fraction < 1 { list.popClip() }
            }
        }
        if FocusChainHolder.current?.focused === node, FocusChainHolder.current?.isFocusVisible == true {
            list.addRoundedRectStroke(bounds, radius: node.theme.radius.sm, width: 2, color: palette.focus.multipliedAlpha(alpha))
        }
    }
}
