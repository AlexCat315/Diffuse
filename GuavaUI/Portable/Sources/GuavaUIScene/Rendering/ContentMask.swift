public import GuavaUICore

/// The rounded mask a clipping container applies to its content and
/// children: its box inset by the border, with the matching inner radius.
/// Square containers need none, since their scissor is already exact.
func contentMask(_ node: Node, x: Float, y: Float, width: Float, height: Float,
                 radius: Float, borderWidth: Float) -> UIRoundedRect? {
    guard node.clipsToBounds, radius > 0, width > 0, height > 0 else { return nil }
    let inset = node.borderColor != nil && borderWidth > 0 ? borderWidth : 0
    let rect = UIRect(x: x + inset, y: y + inset, width: max(0, width - 2 * inset), height: max(0, height - 2 * inset))
    let mask = UIRoundedRect(rect, radius: radius - inset)
    return mask.radius > 0 ? mask : nil
}
