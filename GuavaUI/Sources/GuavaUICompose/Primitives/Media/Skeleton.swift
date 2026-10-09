import Foundation
import GuavaUIRuntime

public enum SkeletonShape: Sendable, Equatable {
    case rectangle(cornerRadius: Float)
    case circle
}

public struct SkeletonAppearance {
    public var shape: SkeletonShape = .rectangle(cornerRadius: 4)
    public var height: Float = 16
    public var color: SemanticColorRef = .onSurfaceMuted.opacity(0.24)
    public var isSecondary = false
    public init() {}
    mutating func validate() {
        height = height.isFinite ? max(1, min(1024, height)) : 16
        if case .rectangle(let radius) = shape {
            shape = .rectangle(cornerRadius: radius.isFinite ? max(0, min(512, radius)) : 4)
        }
    }
}

public struct SkeletonMotion: Sendable, Equatable {
    public var isAnimated = true
    public var duration = 2.0
    public var minimumOpacity: Float = 0.5
    public init() {}
    mutating func validate() {
        duration = duration.isFinite ? max(0.25, min(60, duration)) : 2
        minimumOpacity = minimumOpacity.isFinite ? max(0.1, min(1, minimumOpacity)) : 0.5
    }
    func opacity(phase: Double) -> Float {
        // Smooth extrema, with identical first and last frames of each cycle.
        minimumOpacity + (1 - minimumOpacity) * Float((1 + cos(phase * 2 * .pi)) / 2)
    }
}

/// A decorative placeholder with intrinsic height, shaped painting and a
/// node-owned pulse. The surrounding application owns loading/data/error state.
public struct Skeleton: _PrimitiveView {
    public var appearance = SkeletonAppearance()
    public var motion = SkeletonMotion()
    public init(configure: (inout Self) -> Void = { _ in }) {
        configure(&self); appearance.validate(); motion.validate()
    }
    public func _makeNode() -> Node {
        let node = Node(); node.addResource(LoadingAnimationClock()); return node
    }
    public func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    public func _updateNode(_ node: Node) {
        var appearance = appearance, motion = motion
        appearance.validate(); motion.validate()
        node.isFocusable = false; node.isHitTestable = false
        node.accessibility = AccessibilitySemantics(.image) { $0.isHidden = true }
        let circle = appearance.shape == .circle
        node.layoutNode?.height = appearance.height
        node.layoutNode?.width = circle ? appearance.height : nil
        node.layoutNode?.setMeasureFunc { width, widthMode, height, heightMode in
            if circle {
                let diameter = widthMode == .exactly ? width : heightMode == .exactly ? height : appearance.height
                return CGSize(width: CGFloat(diameter), height: CGFloat(diameter))
            }
            return CGSize(width: CGFloat(widthMode == .undefined ? 120 : width), height: CGFloat(appearance.height))
        }
        let clock = node.firstResource(LoadingAnimationClock.self)!
        let animated = motion.isAnimated && !node.prefersReducedMotion && motion.minimumOpacity < 1
        clock.configure(duration: motion.duration, isActive: animated)
        node.draw = { [weak node] list, origin in
            guard let node else { return }
            var rect = UIRect(x: Float(origin.x), y: Float(origin.y), width: Float(node.frame.width), height: Float(node.frame.height))
            guard rect.x.isFinite, rect.y.isFinite, rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return }
            let opacity = (animated ? motion.opacity(phase: clock.phase) : 1) * (appearance.isSecondary ? 0.5 : 1) * node.opacity
            let color = appearance.color.resolve(node.theme).multipliedAlpha(opacity)
            let radius: Float
            switch appearance.shape {
            case .circle:
                let diameter = min(rect.width, rect.height)
                rect.x += (rect.width - diameter) / 2; rect.y += (rect.height - diameter) / 2
                rect.width = diameter; rect.height = diameter; radius = diameter / 2
            case .rectangle(let cornerRadius): radius = min(cornerRadius, min(rect.width, rect.height) / 2)
            }
            list.addRoundedRect(rect, radius: radius, color: color)
        }
    }
}
