import Foundation
import GuavaUIRuntime

/// Determinate or indeterminate circular progress.
///
/// Reads better than a bar when the indicator sits in a square slot — a
/// toolbar, a table cell, a card corner — where a full-width track would look
/// arbitrary. Set `showsValue` to print the percentage in the middle; leave it
/// off when the number would crowd the ring at small diameters.
///
/// ```swift
/// ProgressCircle(value: 0.72, diameter: 28, showsValue: true)
/// ProgressCircle(value: nil, diameter: 44)   // unknown duration
/// ```
public struct ProgressCircle: _PrimitiveView {
    /// Fraction completed in `0...1`. `nil` renders a rotating arc.
    public var value: Double?
    public var tone: StatusTone
    /// Explicit diameter. `nil` follows the shared `.controlSize`.
    public var diameter: Float?
    /// Ring thickness. `nil` scales with the diameter so the ring keeps the
    /// same visual weight at every size.
    public var thickness: Float?
    public var showsValue: Bool
    public var isEnabled: Bool

    public init(value: Double? = nil,
                diameter: Float? = nil,
                tone: StatusTone = .info,
                configure: (inout Self) -> Void = { _ in }) {
        self.value = value
        self.tone = tone
        self.diameter = diameter
        self.thickness = nil
        self.showsValue = false
        self.isEnabled = true
        configure(&self)
    }

    var clamped: Double {
        guard let value, value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    public func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.addResource(LoadingAnimationClock())
        return node
    }

    public func _makeLayoutNode() -> LayoutNode? { LayoutNode() }

    public func _updateNode(_ node: Node) {
        node.isFocusable = false
        let resolved = clamped
        let indeterminate = value == nil || !(value?.isFinite ?? false)
        let percent = Int((resolved * 100).rounded())
        node.accessibility = AccessibilitySemantics(.progress) {
            $0.label = "Progress"
            $0.value = indeterminate ? "In progress" : "\(percent)%"
            $0.state.isEnabled = isEnabled
        }
        let diameter = resolvedDiameter(in: node)
        node.layoutNode?.width = diameter
        node.layoutNode?.height = diameter
        node.layoutNode?.alignItems = .center
        node.layoutNode?.justifyContent = .center
        // No measure function: `showsValue` puts a label inside this node, and
        // Yoga rejects children on a measured node. The fixed extent is enough —
        // a progress ring is never sized by its content.
        node.layoutNode?.flexShrink = 0

        let clock = node.firstResource(LoadingAnimationClock.self)!
        clock.configure(duration: 1.1, isActive: indeterminate && !node.prefersReducedMotion)

        let identity = DrawIdentity(value: indeterminate ? nil : resolved,
                                     tone: tone,
                                     diameter: diameter,
                                     isEnabled: isEnabled,
                                     indeterminate: indeterminate)
        node.updateDraw(identity: identity) { [weak node] list, origin in
            guard let node else { return }
            let size = min(Float(node.frame.width), Float(node.frame.height))
            guard size > 2 else { return }
            let theme = node.theme
            let base = tone.color.resolve(theme)
            let alpha = node.opacity * (isEnabled ? 1 : 0.5)
            let cx = Float(origin.x) + Float(node.frame.width) / 2
            let cy = Float(origin.y) + Float(node.frame.height) / 2
            let ringThickness = max(1.5, self.resolvedThickness(for: size))
            let outer = size / 2 - ringThickness / 2
            let inner = max(0.5, outer - ringThickness)
            let track = theme.colors.surfaceSunken.multipliedAlpha(alpha)
            paintRing(list: list, cx: cx, cy: cy, inner: inner, outer: outer,
                      from: 0, sweep: 2 * .pi, color: track)
            if indeterminate {
                // A fixed-length arc that rotates; the length is ~35% of the
                // circle so the gap is obvious enough to read as motion.
                let start = Float(clock.phase) * 2 * .pi
                paintRing(list: list, cx: cx, cy: cy, inner: inner, outer: outer,
                          from: start, sweep: .pi * 0.7, color: base.multipliedAlpha(alpha))
            } else {
                let value = Float(resolved)
                guard value > 0 else { return }
                paintRing(list: list, cx: cx, cy: cy, inner: inner, outer: outer,
                          from: -.pi / 2, sweep: 2 * .pi * value, color: base.multipliedAlpha(alpha))
            }
        }
    }

    public func _children(for node: Node) -> [any View] {
        guard showsValue else { return [] }
        let resolved = clamped
        let indeterminate = value == nil || !(value?.isFinite ?? false)
        let percent = Int((resolved * 100).rounded())
        let scale = resolvedDiameter(in: node)
        let size = scale >= 56 ? 13 : scale >= 40 ? 11 : 9
        return [
            Text(indeterminate ? "" : "\(percent)")
                .font(Font.system(size: Float(size), weight: .medium))
                .foregroundColor(isEnabled ? tone.color : .onSurfaceDisabled)
                .accessibilityHidden()
        ]
    }

    private func resolvedDiameter(in node: Node) -> Float {
        if let diameter, diameter.isFinite { return max(12, min(512, diameter)) }
        return switch node.compositionValue(of: ControlSizeEnvironment.key) {
        case .mini: 16
        case .small: 22
        case .regular: 32
        case .large: 44
        }
    }

    func resolvedThickness(for diameter: Float) -> Float {
        if let thickness, thickness.isFinite { return max(1, min(diameter / 2, thickness)) }
        return max(2, diameter * 0.11)
    }

    /// Paints an annulus sector as a triangle strip.
    ///
    /// There is no arc primitive in the draw list, so the ring is tessellated.
    /// Segment count scales with the outer radius so a 64px ring and a 16px
    /// ring both end up with roughly two-pixel facets.
    private func paintRing(list: DrawList,
                           cx: Float, cy: Float,
                           inner: Float, outer: Float,
                           from: Float, sweep: Float,
                           color: Color) {
        guard sweep > 0.001 else { return }
        let segments = max(8, min(120, Int(outer * sweep / 2)))
        let step = sweep / Float(segments)
        var a0 = from
        for _ in 0..<segments {
            let a1 = a0 + step
            let c0 = cos(a0), s0 = sin(a0)
            let c1 = cos(a1), s1 = sin(a1)
            let ix0 = cx + c0 * inner, iy0 = cy + s0 * inner
            let ox0 = cx + c0 * outer, oy0 = cy + s0 * outer
            let ix1 = cx + c1 * inner, iy1 = cy + s1 * inner
            let ox1 = cx + c1 * outer, oy1 = cy + s1 * outer
            list.addTriangle(ix0, iy0, ox0, oy0, ox1, oy1, color: color)
            list.addTriangle(ix0, iy0, ox1, oy1, ix1, iy1, color: color)
            a0 = a1
        }
    }

    private struct DrawIdentity: Equatable {
        let value: Double?
        let tone: StatusTone
        let diameter: Float
        let isEnabled: Bool
        let indeterminate: Bool
    }
}
