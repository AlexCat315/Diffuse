internal import Foundation
import GuavaUIRuntime

/// Cartesian series or pie slices, with per-item visibility from the legend.
enum ChartContent {
    case cartesian(series: [ChartSeries], thresholds: [ChartThreshold], markers: [ChartMarker])
    case pie([ChartSlice])

    var count: Int {
        switch self {
        case .cartesian(let series, _, _): series.count
        case .pie(let slices): slices.count
        }
    }

    func title(_ index: Int) -> String {
        switch self {
        case .cartesian(let series, _, _): series.indices.contains(index) ? series[index].title : ""
        case .pie(let slices): slices.indices.contains(index) ? slices[index].title : ""
        }
    }

    /// The plot rectangle inside a node of `size`.
    static func plotRect(size: CGSize, origin: CGPoint = .zero, style: ChartStyle) -> UIRect {
        let width = Float(size.width), height = Float(size.height)
        let inset = min(style.contentInset, min(width, height) * 0.35)
        return UIRect(x: Float(origin.x) + inset, y: Float(origin.y) + inset,
                      width: max(0, width - inset * 2), height: max(0, height - inset * 2))
    }
}

/// Selection writes coming from input; the chart owns the binding.
struct ChartPlotInput {
    /// Interactive only when the caller supplied a selection binding.
    let isEnabled: Bool
    let select: (ChartPoint?) -> Void
}

/// The drawing and input surface of `Chart`. Hover previews a point on
/// pointer surfaces; press/drag scrubs on touch; arrows step; Escape clears.
struct ChartPlot: _PrimitiveView {
    let content: ChartContent
    let visible: [Bool]
    let style: ChartStyle
    let selection: ChartPoint?
    let summary: (label: String, value: String)
    let callout: ChartCallout?
    let input: ChartPlotInput

    func _makeNode() -> Node {
        let node = Node(), session = ChartSession()
        node.attachments[ChartSession.key] = session
        node.addResource(session)
        return node
    }

    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }

    func _updateLayout(_ layout: LayoutNode) {
        if (layout.height ?? 0) <= 0 { layout.height = 64 }
        layout.minHeight = 24
        layout.minWidth = 0
    }

    func _updateNode(_ node: Node) {
        let session = node.attachments[ChartSession.key] as! ChartSession
        let snapshot = self
        // The session holds the live selection: several events can arrive
        // before the chart recomposes with the binding's new value.
        session.current = selection
        let choose: (ChartPoint?) -> Void = { next in
            session.current = next
            snapshot.input.select(next)
        }
        node.isHitTestable = input.isEnabled
        node.isFocusable = input.isEnabled
        node.cursor = input.isEnabled ? .crosshair : .arrow
        node.accessibility = AccessibilitySemantics(.image) {
            $0.label = summary.label; $0.value = summary.value
            if input.isEnabled { $0.help = "Use Left and Right to move between values, Up and Down between series, Escape to clear" }
        }
        node.accessibilityActions = AccessibilityActions()
        if input.isEnabled {
            node.accessibilityActions.increment = { choose(snapshot.stepped(index: 1, from: session.current)) }
            node.accessibilityActions.decrement = { choose(snapshot.stepped(index: -1, from: session.current)) }
        }
        let theme = node.theme
        node.updateDraw(identity: ChartPaintIdentity(plot: self, theme: theme)) { [weak node] list, origin in
            guard let node else { return }
            snapshot.draw(node: node, origin: origin, list: list)
        }
        guard input.isEnabled, let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node)
            return
        }
        registry.setHover(node) { [weak node] phase in
            guard let node, phase == .leave, !session.isPinned, !session.isPressed, node.supportsControlHover else { return }
            choose(nil)
        }
        registry.setMotion(node) { [weak node] event, phase in
            guard let node, phase == .target else { return .ignored }
            guard session.isPressed || (node.supportsControlHover && !session.isPinned) else { return .ignored }
            let hit = snapshot.hit(x: event.x, y: event.y, node: node)
            // A drag scrubs; leaving the plot keeps the last value.
            if hit != nil || !session.isPressed, hit != session.current { choose(hit) }
            return session.isPressed ? .handled : .ignored
        }
        registry.setPointer(node) { [weak node] event, phase, route in
            guard let node, event.button == .left, route == .target else { return .ignored }
            switch phase {
            case .down:
                let hit = snapshot.hit(x: event.x, y: event.y, node: node)
                // Pressing the pinned point again releases it.
                session.releasesPin = session.isPinned && hit != nil && hit == session.current
                session.press(node: node)
                choose(session.releasesPin ? nil : hit)
            case .up:
                session.release(node: node)
                session.isPinned = !session.releasesPin && session.current != nil
                session.releasesPin = false
            }
            return .handled
        }
        registry.setKey(node) { event, phase in
            guard phase == .target, event.modifiers.isDisjoint(with: [.ctrl, .gui, .alt]) else { return .ignored }
            let current = session.current
            switch event.scancode {
            case Scancode.arrowRight: choose(snapshot.stepped(index: 1, from: current))
            case Scancode.arrowLeft: choose(snapshot.stepped(index: -1, from: current))
            case Scancode.arrowDown: choose(snapshot.stepped(series: 1, from: current))
            case Scancode.arrowUp: choose(snapshot.stepped(series: -1, from: current))
            case Scancode.home: choose(snapshot.jumped(toEnd: false, from: current))
            case Scancode.end: choose(snapshot.jumped(toEnd: true, from: current))
            case Scancode.escape:
                guard current != nil else { return .ignored }
                session.isPinned = false
                choose(nil)
                return .handled
            default: return .ignored
            }
            // A keyboard selection stays until Escape or a pointer moves it.
            session.isPinned = session.current != nil
            return .handled
        }
    }

    /// The callout is laid over the plot at the selected value. Selection only
    /// changes after layout, so the node's frame is current here.
    func _children(for node: Node) -> [any View] {
        guard let callout else { return [] }
        let size = node.frame.size
        let anchor: (x: Float, y: Float)?
        if let geometry = cartesian(in: size), let mark = geometry.mark(callout.point) {
            anchor = (mark.x, mark.bar.map { $0.minY } ?? mark.y)
        } else if let pie = pie(in: size), let wedge = pie.wedges.first(where: { $0.index == callout.point.index }) {
            anchor = pie.anchor(of: wedge)
        } else {
            anchor = nil
        }
        guard let anchor else { return [] }
        return [ChartCalloutLayout(anchorX: CGFloat(anchor.x), anchorY: CGFloat(anchor.y)) {
            Box(direction: .column, alignItems: .flexStart, spacing: 1) {
                Text(callout.title).lineLimit(1).font(.caption).foregroundColor(.onSurfaceMuted)
                Text(callout.value).lineLimit(1).font(.bodyStrong).foregroundColor(.onSurface)
            }
            .padding(horizontal: 8, vertical: 5)
            .background(.surfaceFloating).cornerRadius(.inputRadius).border(.border, width: 1).surfaceFinish()
            .debugName("chart-callout")
        }
        .frame(width: .percent(100), height: .percent(100))
        .absolutePosition(left: 0, top: 0)
        .allowsHitTesting(false)
        .accessibilityHidden()]
    }

    // MARK: Geometry

    func cartesian(in size: CGSize, origin: CGPoint = .zero) -> ChartGeometry? {
        guard case .cartesian(let series, let thresholds, _) = content else { return nil }
        return ChartGeometry(series: series, visible: visible, thresholds: thresholds, style: style,
                             plot: ChartContent.plotRect(size: size, origin: origin, style: style))
    }

    func pie(in size: CGSize, origin: CGPoint = .zero) -> PieGeometry? {
        guard case .pie(let slices) = content else { return nil }
        return PieGeometry(slices: slices, visible: visible, innerRatio: style.innerRadiusRatio,
                           plot: ChartContent.plotRect(size: size, origin: origin, style: style))
    }

    private func hit(x: Float, y: Float, node: Node) -> ChartPoint? {
        let local = (x - Float(node.absoluteOrigin.x), y - Float(node.absoluteOrigin.y))
        if let geometry = cartesian(in: node.frame.size) {
            return geometry.nearest(x: local.0, y: local.1).map { ChartPoint(series: $0.series, index: $0.index) }
        }
        return pie(in: node.frame.size)?.wedge(atX: local.0, y: local.1).map { ChartPoint(series: 0, index: $0.index) }
    }

    /// Visible (series, count) pairs in order; a pie is one series of slices.
    private var tracks: [(series: Int, count: Int)] {
        switch content {
        case .cartesian(let series, _, _):
            series.indices.filter { visible[$0] && !series[$0].values.isEmpty }.map { ($0, series[$0].values.count) }
        case .pie(let slices):
            slices.contains { _ in true } ? [(0, slices.count)] : []
        }
    }

    private func isVisible(_ point: ChartPoint) -> Bool {
        if case .pie(let slices) = content { return visible[point.index] && slices[point.index].value > 0 }
        return true
    }

    func stepped(index delta: Int, from current: ChartPoint?) -> ChartPoint? {
        guard let first = tracks.first else { return current }
        let start = current ?? ChartPoint(series: first.series, index: delta > 0 ? -1 : first.count)
        guard let track = tracks.first(where: { $0.series == start.series }) ?? tracks.first else { return current }
        var next = ChartPoint(series: track.series, index: start.index)
        repeat {
            next.index = max(0, min(track.count - 1, next.index + delta))
        } while !isVisible(next) && next.index > 0 && next.index < track.count - 1
        return isVisible(next) ? next : current
    }

    func stepped(series delta: Int, from current: ChartPoint?) -> ChartPoint? {
        guard case .cartesian = content, !tracks.isEmpty else { return current }
        let position = tracks.firstIndex { $0.series == current?.series } ?? (delta > 0 ? -1 : tracks.count)
        let track = tracks[max(0, min(tracks.count - 1, position + delta))]
        return ChartPoint(series: track.series, index: min(current?.index ?? 0, track.count - 1))
    }

    func jumped(toEnd: Bool, from current: ChartPoint?) -> ChartPoint? {
        guard let track = tracks.first(where: { $0.series == current?.series }) ?? tracks.first else { return current }
        return ChartPoint(series: track.series, index: toEnd ? track.count - 1 : 0)
    }

    // MARK: Drawing

    private func draw(node: Node, origin: CGPoint, list: DrawList) {
        let size = node.frame.size
        guard size.width > 0, size.height > 0 else { return }
        let paint = ChartPaint(theme: node.theme, style: style, selection: selection)
        paint.background(UIRect(x: Float(origin.x), y: Float(origin.y), width: Float(size.width), height: Float(size.height)), list: list)
        switch content {
        case .cartesian(let series, let thresholds, let markers):
            guard let geometry = cartesian(in: size, origin: origin), geometry.plot.width > 0, geometry.plot.height > 0 else { return }
            paint.grid(geometry, list: list)
            paint.thresholds(thresholds, geometry: geometry, list: list)
            paint.series(series, geometry: geometry, list: list)
            paint.markers(markers, geometry: geometry, list: list)
            paint.selection(series, geometry: geometry, list: list)
        case .pie(let slices):
            guard let geometry = pie(in: size, origin: origin) else { return }
            paint.pie(slices, geometry: geometry, list: list)
        }
        if FocusChainHolder.current?.focused === node, FocusChainHolder.current?.isFocusVisible == true {
            list.addRoundedRectStroke(UIRect(x: Float(origin.x), y: Float(origin.y), width: Float(size.width), height: Float(size.height)),
                                      radius: node.theme.radius.sm, width: 2, color: node.theme.colors.focusRing)
        }
    }
}

/// Input state that must survive recomposition: the press and the pin.
final class ChartSession: NodeResource {
    static let key = "chart.session"
    var isPressed = false
    /// A clicked, tapped or keyboard selection stays after the pointer leaves.
    var isPinned = false
    /// The press started on the pinned point, so its release clears the pin.
    var releasesPin = false
    /// The selection as of the latest event, ahead of the binding's recomposition.
    var current: ChartPoint?
    private weak var capture: PointerCapture?
    private weak var focus: FocusChain?

    func mount(node: Node) { capture = PointerCaptureHolder.current; focus = FocusChainHolder.current }
    func unmount(node: Node) {
        release(node: node)
        if focus?.focused === node { focus?.clear() }
    }
    func press(node: Node) { isPressed = true; capture?.acquire(node) }
    func release(node: Node) {
        isPressed = false
        if capture?.target === node { capture?.release() }
    }
}

/// Repaint identity: values, resolved colors and selection.
private struct ChartPaintIdentity: Equatable {
    let values: [[Float]]
    var colors: [Color]
    let marks: [String]
    let visible: [Bool]
    let selection: ChartPoint?
    let thresholds: [Float]
    let markers: [Int]
    let style: [Float]

    init(plot: ChartPlot, theme: Theme) {
        switch plot.content {
        case .cartesian(let series, let thresholds, let markers):
            values = series.map { $0.values + ($0.xValues ?? []) }
            colors = series.map { $0.color.resolve(theme) } + thresholds.map { $0.color.resolve(theme) } + markers.map { $0.color.resolve(theme) }
            marks = series.map { "\($0.mark)" }
            self.thresholds = thresholds.map(\.value)
            self.markers = markers.map(\.index)
        case .pie(let slices):
            values = [slices.map(\.value)]
            colors = slices.indices.map { slices[$0].resolvedColor(at: $0).resolve(theme) }
            marks = ["pie"]
            thresholds = []; markers = []
        }
        visible = plot.visible
        selection = plot.selection
        let style = plot.style
        self.style = [style.minValue ?? .nan, style.maxValue ?? .nan, Float(style.gridLineCount), style.lineWidth,
                      style.barSpacing, style.contentInset, style.innerRadiusRatio, style.stacking == .stacked ? 1 : 0]

        colors += [style.background?.resolve(theme) ?? .clear, style.gridColor.resolve(theme)]
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.values == rhs.values && lhs.colors == rhs.colors && lhs.marks == rhs.marks && lhs.visible == rhs.visible
            && lhs.selection == rhs.selection && lhs.thresholds == rhs.thresholds && lhs.markers == rhs.markers
            && lhs.style.elementsEqual(rhs.style) { $0 == $1 || ($0.isNaN && $1.isNaN) }
    }
}
