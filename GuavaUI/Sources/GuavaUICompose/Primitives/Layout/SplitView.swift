import GuavaUIRuntime

/// Orientation of a `SplitView`.
public enum SplitAxis: Sendable, Hashable {
    /// Panes sit side by side; the divider is vertical.
    case horizontal
    /// Panes stack; the divider is horizontal.
    case vertical
}

/// Two panes sharing one axis, split by a fraction of the available space.
///
/// Pass a `Float` for a layout the application owns, or a `Binding<Float>` for
/// one the user owns — the binding form renders a draggable divider that writes
/// clamped fractions back through it, so the layout can be persisted without
/// the component owning any state.
///
/// ```swift
/// SplitView(.horizontal, fraction: 0.35) { sidebar } second: { content }
/// SplitView(.horizontal, fraction: $sidebarFraction) { sidebar } second: { content }
/// ```
public struct SplitView<First: View, Second: View>: View {
    public typealias Axis = SplitAxis

    public let axis: SplitAxis
    /// Current fraction, whether or not the user can change it.
    public var fraction: Float { fractionBinding?.wrappedValue ?? staticFraction }
    public let spacing: Float
    public let dividerThickness: Float
    public let dividerColor: Color?
    public let constraints: SplitConstraints
    @State private var measuredExtent: Float = 0
    public let first: First
    public let second: Second

    private let fractionBinding: Binding<Float>?
    private let staticFraction: Float

    /// Static split. The application drives `fraction` (a slider, a stored
    /// preference); the divider is a plain separator.
    public init(_ axis: SplitAxis = .horizontal,
                fraction: Float = 0.5,
                spacing: Float = 0,
                dividerThickness: Float = 1,
                dividerColor: Color? = nil,
                constraints: SplitConstraints = .init(fraction: 0.05...0.95),
                @ViewBuilder first: () -> First,
                @ViewBuilder second: () -> Second) {
        self.axis = axis
        self.staticFraction = Self.clampBounds(fraction)
        self.fractionBinding = nil
        self.spacing = spacing
        self.dividerThickness = dividerThickness
        self.dividerColor = dividerColor
        self.constraints = constraints
        self.first = first()
        self.second = second()
    }

    /// User-resizable split. The divider becomes a drag target and keyboard
    /// control that writes clamped fractions into `fraction`.
    public init(_ axis: SplitAxis = .horizontal,
                fraction: Binding<Float>,
                spacing: Float = 0,
                dividerThickness: Float = 1,
                dividerColor: Color? = nil,
                constraints: SplitConstraints = .init(),
                @ViewBuilder first: () -> First,
                @ViewBuilder second: () -> Second) {
        self.axis = axis
        self.staticFraction = Self.clampBounds(fraction.wrappedValue)
        self.fractionBinding = fraction
        self.spacing = spacing
        self.dividerThickness = dividerThickness
        self.dividerColor = dividerColor
        self.constraints = constraints
        self.first = first()
        self.second = second()
    }

    private static func clampBounds(_ value: Float) -> Float {
        guard value.isFinite else { return 0.5 }
        return max(0, min(1, value))
    }

    private var clampedFraction: Float {
        let proposed = fractionBinding?.wrappedValue ?? staticFraction
        let value = proposed.isFinite ? proposed : 0.5
        return max(resolvedRange.lowerBound, min(resolvedRange.upperBound, value))
    }

    private var handleThickness: Float { fractionBinding == nil ? dividerThickness : max(dividerThickness, 7) }
    private var resolvedRange: ClosedRange<Float> {
        constraints.range(available: measuredExtent - handleThickness - 2 * spacing)
    }

    public var body: some View {
        Box(direction: axis.flexDirection, alignItems: .stretch, spacing: spacing) {
            first.flex(clampedFraction, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
            AnyView(divider)
            second.flex(1 - clampedFraction, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
        }
        .clipped()
        .modifier(_SplitExtentObserver(axis: axis, extent: $measuredExtent))
    }

    @ViewBuilder private var divider: some View {
        if let fractionBinding {
            _SplitHandle(axis: axis,
                         thickness: max(dividerThickness, 7),
                         color: dividerColor,
                         fraction: fractionBinding,
                         constraints: constraints,
                         spacing: spacing)
        } else {
            Divider(color: dividerColor, thickness: dividerThickness, axis: axis.dividerAxis)
        }
    }
}

private extension SplitAxis {
    var flexDirection: FlexDirection {
        switch self {
        case .horizontal: .row
        case .vertical: .column
        }
    }

    var dividerAxis: Divider.Axis {
        switch self {
        case .horizontal: .vertical
        case .vertical: .horizontal
        }
    }

    /// Cursor shown over the divider, and the key axis that shrinks the first
    /// pane. Both follow the direction the divider travels, not the direction
    /// the panes are laid out.
    var resizeCursor: SystemCursor {
        switch self {
        case .horizontal: .resizeHorizontal
        case .vertical: .resizeVertical
        }
    }
}

/// Divider that converts pointer travel into a fraction of its container.
///
/// The container extent is sampled from the parent node at drag start rather
/// than from the handle, so a drag that leaves the handle still tracks — the
/// handle captures the pointer for the whole gesture.
private struct _SplitHandle: _PrimitiveView {
    let axis: SplitAxis
    let thickness: Float
    let color: Color?
    let fraction: Binding<Float>
    let constraints: SplitConstraints
    let spacing: Float

    func _makeNode() -> Node { Node() }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexShrink = 0
        layout.alignSelf = .stretch
        switch axis {
        case .horizontal: layout.width = thickness
        case .vertical: layout.height = thickness
        }
        return layout
    }

    func _updateNode(_ node: Node) {
        node.isHitTestable = true
        node.isFocusable = true
        node.isTabStop = true
        node.cursor = axis.resizeCursor
        let range = constraints.range(available: containerExtent(node))
        let current = max(range.lowerBound, min(range.upperBound, fraction.wrappedValue.isFinite ? fraction.wrappedValue : 0.5))
        node.accessibility = AccessibilitySemantics(.slider) {
            $0.label = "Resize split"
            $0.value = "\(Int((current * 100).rounded()))%"
        }
        node.accessibilityActions.increment = { adjust(node: node, by: 0.02) }
        node.accessibilityActions.decrement = { adjust(node: node, by: -0.02) }
        // Grab area painted inset from the divider line, so the visual weight
        // stays a hairline while the hit target stays usable.
        node.updateDraw(identity: DrawIdentity(color: color?.rgba8, thickness: thickness)) { [weak node] list, origin in
            guard let node else { return }
            let theme = node.theme
            let resolved = color ?? theme.colors.divider
            let rect: UIRect
            switch axis {
            case .horizontal:
                let x = Float(origin.x) + Float(node.frame.width - 1) / 2
                rect = UIRect(x: x, y: Float(origin.y), width: 1, height: Float(node.frame.height))
            case .vertical:
                let y = Float(origin.y) + Float(node.frame.height - 1) / 2
                rect = UIRect(x: Float(origin.x), y: y, width: Float(node.frame.width), height: 1)
            }
            guard rect.width > 0, rect.height > 0 else { return }
            list.addRect(rect, color: resolved.multipliedAlpha(node.opacity))
        }
        guard let registry = InteractionRegistryHolder.current else { return }
        registry.setPointer(node) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                let extent = containerExtent(node)
                let range = constraints.range(available: extent)
                let proposed = fraction.wrappedValue.isFinite ? fraction.wrappedValue : 0.5
                let resolved = max(range.lowerBound, min(range.upperBound, proposed))
                node.attachments[Keys.start] = Start(fraction: resolved,
                                                     position: axis == .horizontal ? event.x : event.y,
                                                     extent: extent)
                PointerCaptureHolder.current?.acquire(node)
            case .up:
                node.attachments.removeValue(forKey: Keys.start)
                if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
            }
            return .handled
        }
        registry.setMotion(node) { event, _ in
            guard PointerCaptureHolder.current?.target === node,
                  let start = node.attachments[Keys.start] as? Start,
                  start.extent > 1 else { return .ignored }
            let position: Float = axis == .horizontal ? event.x : event.y
            write(start.fraction + (position - start.position) / start.extent, node: node)
            return .handled
        }
        registry.setKey(node) { event, phase in
            guard phase == .target, event.modifiers.isDisjoint(with: [.ctrl, .gui, .alt]) else { return .ignored }
            let step: Float = 0.02
            switch axis {
            case .horizontal:
                switch event.scancode {
                case Scancode.arrowLeft: adjust(node: node, by: -step)
                case Scancode.arrowRight: adjust(node: node, by: step)
                default: return .ignored
                }
            case .vertical:
                switch event.scancode {
                case Scancode.arrowUp: adjust(node: node, by: -step)
                case Scancode.arrowDown: adjust(node: node, by: step)
                default: return .ignored
                }
            }
            return .handled
        }
    }

    var _children: [any View] { [] }

    private enum Keys {
        static let start = "splitview.dragStart"
    }

    private struct Start {
        let fraction: Float
        let position: Float
        let extent: Float
    }

    private struct DrawIdentity: Equatable {
        let color: UInt32?
        let thickness: Float
    }

    private func containerExtent(_ node: Node) -> Float {
        let container = node.parent?.frame ?? node.frame
        let extent = axis == .horizontal ? Float(container.width) : Float(container.height)
        return max(0, extent - thickness - 2 * spacing)
    }

    private func write(_ value: Float, node: Node) {
        guard value.isFinite else { return }
        let range = constraints.range(available: containerExtent(node))
        let clamped = max(range.lowerBound, min(range.upperBound, value))
        if fraction.wrappedValue != clamped { fraction.wrappedValue = clamped }
    }

    private func adjust(node: Node, by delta: Float) {
        let range = constraints.range(available: containerExtent(node))
        let proposed = fraction.wrappedValue.isFinite ? fraction.wrappedValue : 0.5
        let current = max(range.lowerBound, min(range.upperBound, proposed))
        write(current + delta, node: node)
    }
}

private final class _SplitMeasurement {
    var axis: SplitAxis
    var extent: Binding<Float>
    init(axis: SplitAxis, extent: Binding<Float>) { self.axis = axis; self.extent = extent }
    func update(_ node: Node) {
        let next = axis == .horizontal ? Float(node.frame.width) : Float(node.frame.height)
        if extent.wrappedValue != next { extent.wrappedValue = next }
    }
}

private struct _SplitExtentObserver: ViewModifier {
    let axis: SplitAxis
    let extent: Binding<Float>
    private static var key: String { "GuavaUI.split.measurement" }
    func apply(node: Node) {
        if let measurement = node.attachments[Self.key] as? _SplitMeasurement {
            measurement.axis = axis
            measurement.extent = extent
            return
        }
        let measurement = _SplitMeasurement(axis: axis, extent: extent)
        node.attachments[Self.key] = measurement
        let previous = node.layoutDidUpdate
        // Install once; repeated recomposition updates the owner above instead
        // of retaining a growing chain of obsolete measurement callbacks.
        node.layoutDidUpdate = { node in
            previous?(node)
            measurement.update(node)
        }
    }
}
