import GuavaUIRuntime

/// A faint upper edge and a shallow shadow: material without glass or gradients.
public struct SurfaceFinishModifier: ViewModifier {
    public init() {}

    public func apply(node: Node) {
        let shadow = node.theme.elevation.low
        node.shadowColor = shadow.color
        node.shadowOffsetX = shadow.offsetX
        node.shadowOffsetY = shadow.offsetY
        node.shadowBlur = shadow.blur
        node.updateOverlayDraw(identity: node.theme.colors.border) { [weak node] list, origin in
            guard let node else { return }
            let inset = node.cornerRadius
            list.addRect(UIRect(x: Float(origin.x) + inset, y: Float(origin.y),
                                width: max(0, Float(node.frame.width) - inset * 2), height: 1),
                         color: node.theme.colors.border.multipliedAlpha(0.4 * node.opacity))
        }
    }
}

public extension View {
    func surfaceFinish() -> some View { modifier(SurfaceFinishModifier()) }
}
