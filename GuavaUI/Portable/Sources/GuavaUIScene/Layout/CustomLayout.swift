import Foundation
import CYoga

struct LayoutCalculationState {
    var subtreeDirty = false
    var custom: CustomLayoutState?
    var placedFrame: CGRect?
    var placementIsVisible = true
}

/// The Compose adapter owns the public value-based layout API. This bridge
/// keeps Yoga ownership and temporary measurement trees inside Scene.
final class CustomLayoutState {
    typealias Measure = (CGFloat?, CGFloat?, [LayoutNode]) -> CGSize
    typealias Place = (CGRect, [LayoutNode]) -> Void
    var measure: Measure
    var place: Place
    private var probes: [ObjectIdentifier: LayoutProbe] = [:]
    private var measurements: [ObjectIdentifier: [(Proposal, CGSize)]] = [:]
    private var placementBounds: CGRect?
    private var placementDirection: Direction?

    struct Proposal: Equatable {
        let width: CGFloat?
        let height: CGFloat?
        let direction: Direction
    }

    init(measure: @escaping Measure, place: @escaping Place) {
        self.measure = measure
        self.place = place
    }

    func invalidate() {
        measurements.removeAll(keepingCapacity: true)
        placementBounds = nil
        placementDirection = nil
    }

    func remove(_ child: LayoutNode) {
        measurements.removeValue(forKey: ObjectIdentifier(child))
        probes.removeValue(forKey: ObjectIdentifier(child))
        child.calculation.placedFrame = nil
        child.calculation.placementIsVisible = true
    }

    func size(of child: LayoutNode, width: CGFloat?, height: CGFloat?, direction: Direction) -> CGSize {
        let key = Proposal(width: width, height: height, direction: direction)
        let id = ObjectIdentifier(child)
        if let cached = measurements[id]?.first(where: { $0.0 == key }) { return cached.1 }
        // Probing reuses the child's Yoga tree and can change descendant
        // geometry. Even when our final bounds stay equal, restore placement
        // after a new probe rather than retaining geometry from measurement.
        placementBounds = nil
        placementDirection = nil
        layout(child, width: width, height: height, direction: direction)
        let result = child.yogaFrame.size
        var entries = measurements[id] ?? []
        if entries.count == 4 { entries.removeFirst() }
        entries.append((key, result))
        measurements[id] = entries
        return result
    }

    func layout(_ child: LayoutNode, width: CGFloat?, height: CGFloat?, direction: Direction) {
        let id = ObjectIdentifier(child)
        let probe: LayoutProbe
        if let existing = probes[id] { probe = existing }
        else {
            probe = LayoutProbe(child)
            probes[id] = probe
        }
        // A flex-start probe gives children an at-most proposal, rather than
        // turning an intrinsic measurement into an exact root size. Authored
        // fixed dimensions and minimums remain authoritative.
        YGNodeStyleSetWidth(probe.node, width.map(Float.init) ?? .nan)
        YGNodeStyleSetHeight(probe.node, height.map(Float.init) ?? .nan)
        child.prepareCustomLayouts()
        YGNodeCalculateLayout(probe.node, width.map(Float.init) ?? .nan,
                              height.map(Float.init) ?? .nan, direction.ygValue)
    }

    func placeIfNeeded(bounds: CGRect, direction: Direction, children: [LayoutNode]) {
        guard placementBounds != bounds || placementDirection != direction else { return }
        placementBounds = bounds
        placementDirection = direction
        place(bounds, children)
    }
}

/// Yoga clears a child's calculated geometry when removing it from a parent.
/// Keep one small probe per child, rather than detach/reinsert after measuring.
/// Holding the child here also makes destruction order explicit.
private final class LayoutProbe {
    let node = YGNodeNew()
    let child: LayoutNode

    init(_ child: LayoutNode) {
        self.child = child
        YGNodeStyleSetFlexDirection(node, .column)
        YGNodeStyleSetAlignItems(node, .flexStart)
        YGNodeInsertChild(node, child.ygNode, 0)
    }

    deinit {
        YGNodeRemoveChild(node, child.ygNode)
        YGNodeFree(node)
    }
}

extension LayoutNode {
    @_spi(CustomLayout) public func setCustomLayout(
        measure: @escaping (CGFloat?, CGFloat?, [LayoutNode]) -> CGSize,
        place: @escaping (CGRect, [LayoutNode]) -> Void
    ) {
        if let state = calculation.custom {
            state.measure = measure
            state.place = place
            state.invalidate()
            markDirty()
        } else {
            for child in children { YGNodeRemoveChild(ygNode, child.ygNode) }
            calculation.custom = CustomLayoutState(measure: measure, place: place)
            setMeasureFunc { [weak self] width, widthMode, height, heightMode in
                guard let self, let state = self.calculation.custom else { return .zero }
                return state.measure(widthMode == .undefined ? nil : CGFloat(width),
                                     heightMode == .undefined ? nil : CGFloat(height), self.children)
            }
        }
    }

    @_spi(CustomLayout) public var customLayoutDirection: Direction {
        if direction != .inherit { return direction }
        return parent?.customLayoutDirection ?? (YGNodeLayoutGetDirection(ygNode) == .RTL ? .rtl : .ltr)
    }

    @_spi(CustomLayout) public func measureForCustomLayout(width: CGFloat?, height: CGFloat?) -> CGSize {
        guard let owner = parent?.calculation.custom else { return .zero }
        return owner.size(of: self, width: width, height: height, direction: customLayoutDirection)
    }

    @_spi(CustomLayout) public var customLayoutIsVisible: Bool { calculation.placementIsVisible }

    @_spi(CustomLayout) public func placeForCustomLayout(at point: CGPoint, width: CGFloat?, height: CGFloat?, isVisible: Bool) {
        guard let owner = parent?.calculation.custom else { return }
        calculation.placementIsVisible = isVisible
        guard isVisible else { calculation.placedFrame = .zero; return }
        owner.layout(self, width: width, height: height, direction: customLayoutDirection)
        placeCustomLayouts()
        calculation.placedFrame = CGRect(origin: point, size: yogaFrame.size)
    }

    func prepareCustomLayouts() {
        guard subtreeIsDirty else { return }
        calculation.custom?.invalidate()
        for child in children { child.prepareCustomLayouts() }
    }

    func placeCustomLayouts() {
        if let state = calculation.custom {
            let padding = resolvedPadding
            let border = resolvedBorder
            let left = CGFloat(padding.left + border.left)
            let top = CGFloat(padding.top + border.top)
            let size = yogaFrame.size
            let bounds = CGRect(x: left, y: top,
                                width: max(0, size.width - left - CGFloat(padding.right + border.right)),
                                height: max(0, size.height - top - CGFloat(padding.bottom + border.bottom)))
            state.placeIfNeeded(bounds: bounds, direction: customLayoutDirection, children: children)
        } else {
            for child in children { child.placeCustomLayouts() }
        }
    }
}
