import GuavaUIRuntime

/// One axis mapping shared by input, fill, thumb and ticks.
struct SliderGeometry {
    let axis: Slider.Axis
    let length: Float
    let breadth: Float
    let isReversed: Bool

    init(node: Node, axis: Slider.Axis) {
        self.axis = axis
        length = Float(axis == .horizontal ? node.frame.width : node.frame.height)
        breadth = Float(axis == .horizontal ? node.frame.height : node.frame.width)
        var layout = node.layoutNode
        while let current = layout, current.direction == .inherit { layout = current.parent }
        isReversed = axis == .vertical || layout?.direction == .rtl
    }

    func valueFraction(at position: Float) -> Float {
        let fraction = min(1, max(0, position / max(1, length)))
        return isReversed ? 1 - fraction : fraction
    }

    func position(for fraction: Float) -> Float {
        (isReversed ? 1 - fraction : fraction) * length
    }

    func rect(at start: Float, length extent: Float, thickness: Float, origin: CGPoint) -> UIRect {
        let cross = (breadth - thickness) / 2
        return axis == .horizontal
            ? UIRect(x: Float(origin.x) + start, y: Float(origin.y) + cross, width: extent, height: thickness)
            : UIRect(x: Float(origin.x) + cross, y: Float(origin.y) + start, width: thickness, height: extent)
    }
}
