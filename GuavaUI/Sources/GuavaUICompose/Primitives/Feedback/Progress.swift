import Foundation
import GuavaUIRuntime

/// Determinate or indeterminate linear progress.
///
/// Pass `nil` for `value` to switch to the indeterminate sweep, which is the
/// honest representation when the total work is unknown — a fake 30% that never
/// advances is worse than admitting the wait.
///
/// The sweep is driven by a clock owned by the node, so it starts and stops
/// with the view's lifetime and respects the system reduced-motion preference.
///
/// ```swift
/// ProgressView(value: fractionComplete, tone: .success)
/// ProgressView(value: nil)   // unknown duration
/// ```
public struct ProgressView: _PrimitiveView {
    /// Fraction completed in `0...1`. `nil` renders the indeterminate sweep.
    public var value: Double?
    public var tone: StatusTone
    /// Explicit track thickness. `nil` follows the shared `.controlSize`.
    public var height: Float?
    public var isEnabled: Bool

    public init(value: Double? = nil,
                tone: StatusTone = .info,
                configure: (inout Self) -> Void = { _ in }) {
        self.value = value
        self.tone = tone
        self.height = nil
        self.isEnabled = true
        configure(&self)
    }

    /// `value` forced into `0...1`; `nil` and non-finite values read as `0`
    /// because drawing a 250%-wide fill is never the honest answer.
    var clamped: Double {
        guard let value, value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    public func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.addResource(LoadingAnimationClock())
        node.addResource(ProgressValue())
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
        let height = resolvedHeight(in: node)
        node.layoutNode?.height = height
        node.layoutNode?.setMeasureFunc { width, widthMode, _, _ in
            CGSize(width: CGFloat(widthMode == .undefined ? 160 : width), height: CGFloat(height))
        }

        let clock = node.firstResource(LoadingAnimationClock.self)!
        clock.configure(duration: 1.4, isActive: indeterminate && !node.prefersReducedMotion)

        let presentation = node.firstResource(ProgressValue.self)!
        presentation.update(node: node, target: resolved, determinate: !indeterminate)

        let identity = DrawIdentity(value: indeterminate ? nil : resolved,
                                     tone: tone,
                                     height: height,
                                     isEnabled: isEnabled,
                                     indeterminate: indeterminate)
        node.updateDraw(identity: identity) { [weak node] list, origin in
            guard let node else { return }
            let rect = UIRect(x: Float(origin.x), y: Float(origin.y),
                              width: Float(node.frame.width), height: Float(node.frame.height))
            guard rect.width > 0, rect.height > 0 else { return }
            let theme = node.theme
            let base = tone.color.resolve(theme)
            let alpha = node.opacity * (isEnabled ? 1 : 0.5)
            let radius = rect.height / 2
            list.addRoundedRect(rect, radius: radius,
                                color: theme.colors.surfaceVariant.multipliedAlpha(alpha))
            guard rect.width > rect.height else { return }
            if indeterminate {
                let phase = Float(clock.phase)
                // Ping-pong with a smoothstep so the sweep eases at both ends
                // instead of snapping direction.
                let triangle = phase < 0.5 ? phase * 2 : (1 - phase) * 2
                let eased = triangle * triangle * (3 - 2 * triangle)
                let segmentWidth = max(rect.height, rect.width * 0.4)
                let x = rect.x + (rect.width - segmentWidth) * eased
                let segment = UIRect(x: x, y: rect.y, width: segmentWidth, height: rect.height)
                list.addRoundedRect(segment, radius: radius, color: base.multipliedAlpha(alpha))
            } else {
                let filled = rect.width * Float(presentation.value)
                guard filled > 0 else { return }
                let fill = UIRect(x: rect.x, y: rect.y, width: filled, height: rect.height)
                list.addRoundedRect(fill, radius: min(radius, filled / 2), color: base.multipliedAlpha(alpha))
            }
        }
    }

    private func resolvedHeight(in node: Node) -> Float {
        if let height, height.isFinite { return max(2, min(64, height)) }
        return switch node.compositionValue(of: ControlSizeEnvironment.key) {
        case .mini: 3
        case .small: 4
        case .regular: 6
        case .large: 8
        }
    }

    private struct DrawIdentity: Equatable {
        let value: Double?
        let tone: StatusTone
        let height: Float
        let isEnabled: Bool
        let indeterminate: Bool
    }
}
