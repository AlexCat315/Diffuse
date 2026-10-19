import GuavaUIRuntime

extension SliderHost {
    func render(node: Node, style: AnySliderStyle, origin: CGPoint, list: DrawList) {
        let appearance = style.resolve(SliderStyleConfiguration(
            value: clampedValue(value.wrappedValue), range: range,
            isPressed: node.attachments[Self.pressedKey] as? Bool ?? false,
            isHovered: node.attachments[Self.hoveredKey] as? Bool ?? false,
            isFocused: FocusChainHolder.current?.focused === node
                && FocusChainHolder.current?.isFocusVisible == true,
            isEnabled: isEnabled, theme: node.theme))
        let geometry = SliderGeometry(node: node, axis: axis)
        guard geometry.length > 0, geometry.breadth > 0 else { return }
        list.addRoundedRect(geometry.rect(at: 0, length: geometry.length,
            thickness: appearance.trackHeight, origin: origin),
            radius: appearance.trackCornerRadius, color: appearance.trackColor)

        let span = range.upperBound - range.lowerBound
        let fraction = span > 0 ? Float((clampedValue(value.wrappedValue) - range.lowerBound) / span) : 0
        let position = geometry.position(for: fraction)
        let fillStart = geometry.isReversed ? position : 0
        let fillLength = geometry.isReversed ? geometry.length - position : position
        if fillLength > 0 {
            list.addRoundedRect(geometry.rect(at: fillStart, length: fillLength,
                thickness: appearance.trackHeight, origin: origin),
                radius: appearance.trackCornerRadius, color: appearance.fillColor)
        }

        if showsTicks, let step, span.isFinite, span > 0 {
            let count = (span / step).rounded(.down)
            // Small dots inside the track: light over the fill, muted beyond it,
            // hidden under the thumb, and omitted when they would crowd together.
            let spacing = count > 0 ? geometry.length / Float(count) : 0
            if count.isFinite, count >= 1, count <= 40, spacing >= 10 {
                let dot = max(2, min(3, appearance.trackHeight - 1))
                let thumbHalf = appearance.thumbDiameter / 2 + 1
                for index in 0...Int(count) {
                    let tick = geometry.position(for: Float(Double(index) * step / span))
                    guard abs(tick - position) > thumbHalf else { continue }
                    let filled = tick >= fillStart && tick <= fillStart + fillLength
                    let color = filled ? node.theme.colors.onAccent.multipliedAlpha(0.7) : node.theme.colors.onSurfaceMuted.multipliedAlpha(0.55)
                    list.addRoundedRect(geometry.rect(
                        at: min(max(0, tick - dot / 2), max(0, geometry.length - dot)), length: dot,
                        thickness: dot, origin: origin), radius: dot / 2, color: color)
                }
            }
        }

        let diameter = min(appearance.thumbDiameter, geometry.length, geometry.breadth)
        let half = diameter / 2
        let centre = min(max(half, position), geometry.length - half)
        let thumb = geometry.rect(at: centre - half, length: diameter, thickness: diameter, origin: origin)
        if let border = appearance.thumbBorderColor, appearance.thumbBorderWidth > 0 {
            let width = appearance.thumbBorderWidth
            list.addRoundedRect(UIRect(x: thumb.minX - width, y: thumb.minY - width,
                width: diameter + 2 * width, height: diameter + 2 * width),
                radius: half + width, color: border)
        }
        list.addRoundedRect(thumb, radius: half, color: appearance.thumbColor)
    }
}
