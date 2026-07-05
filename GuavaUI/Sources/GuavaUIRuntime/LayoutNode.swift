import CYoga
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

private enum LayoutStyleValue: Equatable {
    case points(Float)
    case percent(Float)
    case auto
}

/// Wraps a `YGNodeRef` and owns its lifetime.
///
/// Create a `LayoutNode` for every `Node` that participates in flexbox layout,
/// mirroring the GuavaUI node tree. After calling `calculateLayout()` on the root,
/// read back `frame` to obtain the Yoga-computed rectangle.
///
/// - Important: The tree owns its children — adding a `LayoutNode` as a child
///   transfers responsibility for its memory to the parent.
public final class LayoutNode: @unchecked Sendable {

    let ygNode: YGNodeRef

    /// Retained children — prevents the underlying YGNodeRefs from dangling.
    public private(set) var children: [LayoutNode] = []

    private weak var parent: LayoutNode?
    private var subtreeLayoutDirtyHint = false

    /// Side table for style metadata that affects measurement but is not part
    /// of Yoga's native style surface.
    public var attachments: [String: Any] = [:]

    private var flexBasisStyle: LayoutStyleValue = .auto
    private var widthStyle: LayoutStyleValue = .auto
    private var heightStyle: LayoutStyleValue = .auto
    private var positionStyles: [Edge: LayoutStyleValue] = [:]
    private var marginStyles: [Edge: LayoutStyleValue] = [:]
    private var paddingStyles: [Edge: LayoutStyleValue] = [:]
    private var borderStyles: [Edge: Float] = [:]
    private var gapStyles: [Gutter: LayoutStyleValue] = [:]

    // MARK: - Phase 6: typed text measure slot
    //
    // The text-measure cache used to live in two places: an NSMapTable on
    // `LayoutTree` plus a stringly-keyed entry in `attachments`. With the
    // small types lifted into Runtime (`TextMeasureSlot.swift`), the cache
    // becomes a single stored property here and `LayoutTree` no longer
    // needs the side table at all.

    /// Cached shape+layout result. Written by the measure callback, read
    /// by the draw callback. `nil` until the first measure runs.
    public var textMeasure: TextLayoutCacheEntry?

    /// Last-seen text measure inputs. `_updateLayout` compares the previous
    /// value against the next to decide whether to mark the node dirty.
    public var textInputs: TextMeasureInputs?

    // MARK: - Init / deinit

    public init() {
        ygNode = YGNodeNew()
    }

    deinit {
        YGNodeFree(ygNode)
    }

    // MARK: - Tree

    public func addChild(_ child: LayoutNode) {
        YGNodeInsertChild(ygNode, child.ygNode, children.count)
        child.parent = self
        children.append(child)
        markLayoutDirtyHint()
    }

    public func removeChild(_ child: LayoutNode) {
        YGNodeRemoveChild(ygNode, child.ygNode)
        let previousCount = children.count
        children.removeAll { $0 === child }
        if children.count != previousCount {
            child.parent = nil
            markLayoutDirtyHint()
        }
    }

    /// Reassign this node's children to `ordered` (which must be exactly the
    /// same set as the current children). Used by the keyed reconciler after
    /// reordering the matching `Node` tree, so Yoga sees siblings in the same
    /// final sequence.
    public func reorderChildren(_ ordered: [LayoutNode]) {
        precondition(ordered.count == children.count,
                     "LayoutNode.reorderChildren: count mismatch")
        let currentIDs = Set(children.map { ObjectIdentifier($0) })
        let nextIDs = Set(ordered.map { ObjectIdentifier($0) })
        precondition(currentIDs == nextIDs,
                     "LayoutNode.reorderChildren: membership mismatch")
        if children.elementsEqual(ordered, by: { $0 === $1 }) {
            return
        }
        // Yoga's removeChild + insertChild keeps the YGNode wired to this
        // parent across the reorder; we rebuild the sequence under the same
        // YGNode. Children's heap allocations stay alive via `self.children`
        // throughout.
        for c in children {
            YGNodeRemoveChild(ygNode, c.ygNode)
        }
        for (index, c) in ordered.enumerated() {
            YGNodeInsertChild(ygNode, c.ygNode, index)
        }
        children = ordered
        markLayoutDirtyHint()
    }

    // MARK: - Style setters (container)

    public var direction: Direction = .inherit {
        didSet {
            guard oldValue != direction else { return }
            YGNodeStyleSetDirection(ygNode, direction.ygValue)
            markLayoutDirtyHint()
        }
    }

    public var flexDirection: FlexDirection = .column {
        didSet {
            guard oldValue != flexDirection else { return }
            YGNodeStyleSetFlexDirection(ygNode, flexDirection.ygValue)
            markLayoutDirtyHint()
        }
    }

    public var alignItems: Align = .stretch {
        didSet {
            guard oldValue != alignItems else { return }
            YGNodeStyleSetAlignItems(ygNode, alignItems.ygValue)
            markLayoutDirtyHint()
        }
    }

    public var alignContent: Align = .flexStart {
        didSet {
            guard oldValue != alignContent else { return }
            YGNodeStyleSetAlignContent(ygNode, alignContent.ygValue)
            markLayoutDirtyHint()
        }
    }

    public var justifyContent: Justify = .flexStart {
        didSet {
            guard oldValue != justifyContent else { return }
            YGNodeStyleSetJustifyContent(ygNode, justifyContent.ygValue)
            markLayoutDirtyHint()
        }
    }

    public var flexWrap: Wrap = .noWrap {
        didSet {
            guard oldValue != flexWrap else { return }
            YGNodeStyleSetFlexWrap(ygNode, flexWrap.ygValue)
            markLayoutDirtyHint()
        }
    }

    public var overflow: Overflow = .visible {
        didSet {
            guard oldValue != overflow else { return }
            YGNodeStyleSetOverflow(ygNode, overflow.ygValue)
            markLayoutDirtyHint()
        }
    }

    public var display: Display = .flex {
        didSet {
            guard oldValue != display else { return }
            YGNodeStyleSetDisplay(ygNode, display.ygValue)
            markLayoutDirtyHint()
        }
    }

    // MARK: - Style setters (child)

    public var alignSelf: Align = .auto {
        didSet {
            guard oldValue != alignSelf else { return }
            YGNodeStyleSetAlignSelf(ygNode, alignSelf.ygValue)
            markLayoutDirtyHint()
        }
    }

    public var positionType: PositionType = .relative {
        didSet {
            guard oldValue != positionType else { return }
            YGNodeStyleSetPositionType(ygNode, positionType.ygValue)
            markLayoutDirtyHint()
        }
    }

    public var flex: Float = 0 {
        didSet {
            guard oldValue != flex else { return }
            YGNodeStyleSetFlex(ygNode, flex)
            markLayoutDirtyHint()
        }
    }

    public var flexGrow: Float = 0 {
        didSet {
            guard oldValue != flexGrow else { return }
            YGNodeStyleSetFlexGrow(ygNode, flexGrow)
            markLayoutDirtyHint()
        }
    }

    public var flexShrink: Float = 0 {
        didSet {
            guard oldValue != flexShrink else { return }
            YGNodeStyleSetFlexShrink(ygNode, flexShrink)
            markLayoutDirtyHint()
        }
    }

    // MARK: - Flex basis

    public func setFlexBasis(_ value: Float) {
        guard flexBasisStyle != .points(value) else { return }
        flexBasisStyle = .points(value)
        YGNodeStyleSetFlexBasis(ygNode, value)
        markLayoutDirtyHint()
    }

    public func setFlexBasisPercent(_ value: Float) {
        guard flexBasisStyle != .percent(value) else { return }
        flexBasisStyle = .percent(value)
        YGNodeStyleSetFlexBasisPercent(ygNode, value)
        markLayoutDirtyHint()
    }

    public func setFlexBasisAuto() {
        guard flexBasisStyle != .auto else { return }
        flexBasisStyle = .auto
        YGNodeStyleSetFlexBasisAuto(ygNode)
        markLayoutDirtyHint()
    }

    // MARK: - Dimensions

    public var width: Float? {
        didSet {
            applyWidthStyle(width.map(LayoutStyleValue.points) ?? .auto)
        }
    }

    public var minWidth: Float? {
        didSet {
            guard oldValue != minWidth else { return }
            if let w = minWidth { YGNodeStyleSetMinWidth(ygNode, w) }
            else { YGNodeStyleSetMinWidth(ygNode, .nan) }
            markLayoutDirtyHint()
        }
    }

    public var maxWidth: Float? {
        didSet {
            guard oldValue != maxWidth else { return }
            if let w = maxWidth { YGNodeStyleSetMaxWidth(ygNode, w) }
            else { YGNodeStyleSetMaxWidth(ygNode, .nan) }
            markLayoutDirtyHint()
        }
    }

    public func setWidthPercent(_ value: Float) {
        applyWidthStyle(.percent(value))
    }

    public var height: Float? {
        didSet {
            applyHeightStyle(height.map(LayoutStyleValue.points) ?? .auto)
        }
    }

    public var minHeight: Float? {
        didSet {
            guard oldValue != minHeight else { return }
            if let h = minHeight { YGNodeStyleSetMinHeight(ygNode, h) }
            else { YGNodeStyleSetMinHeight(ygNode, .nan) }
            markLayoutDirtyHint()
        }
    }

    public var maxHeight: Float? {
        didSet {
            guard oldValue != maxHeight else { return }
            if let h = maxHeight { YGNodeStyleSetMaxHeight(ygNode, h) }
            else { YGNodeStyleSetMaxHeight(ygNode, .nan) }
            markLayoutDirtyHint()
        }
    }

    public func setHeightPercent(_ value: Float) {
        applyHeightStyle(.percent(value))
    }

    // MARK: - Position / Margin / Padding / Border

    public func setPosition(_ value: Float, edge: Edge) {
        guard positionStyles[edge] != .points(value) else { return }
        positionStyles[edge] = .points(value)
        YGNodeStyleSetPosition(ygNode, edge.ygValue, value)
        markLayoutDirtyHint()
    }

    public func setPositionPercent(_ value: Float, edge: Edge) {
        guard positionStyles[edge] != .percent(value) else { return }
        positionStyles[edge] = .percent(value)
        YGNodeStyleSetPositionPercent(ygNode, edge.ygValue, value)
        markLayoutDirtyHint()
    }

    public func setPositionAuto(edge: Edge) {
        guard positionStyles[edge] != .auto else { return }
        positionStyles[edge] = .auto
        YGNodeStyleSetPositionAuto(ygNode, edge.ygValue)
        markLayoutDirtyHint()
    }

    public func setMargin(_ value: Float, edge: Edge = .all) {
        guard marginStyles[edge] != .points(value) else { return }
        marginStyles[edge] = .points(value)
        YGNodeStyleSetMargin(ygNode, edge.ygValue, value)
        markLayoutDirtyHint()
    }

    public func setMarginPercent(_ value: Float, edge: Edge = .all) {
        guard marginStyles[edge] != .percent(value) else { return }
        marginStyles[edge] = .percent(value)
        YGNodeStyleSetMarginPercent(ygNode, edge.ygValue, value)
        markLayoutDirtyHint()
    }

    public func setMarginAuto(edge: Edge = .all) {
        guard marginStyles[edge] != .auto else { return }
        marginStyles[edge] = .auto
        YGNodeStyleSetMarginAuto(ygNode, edge.ygValue)
        markLayoutDirtyHint()
    }

    public func setPadding(_ value: Float, edge: Edge = .all) {
        guard paddingStyles[edge] != .points(value) else { return }
        paddingStyles[edge] = .points(value)
        YGNodeStyleSetPadding(ygNode, edge.ygValue, value)
        markLayoutDirtyHint()
    }

    public func setPaddingPercent(_ value: Float, edge: Edge = .all) {
        guard paddingStyles[edge] != .percent(value) else { return }
        paddingStyles[edge] = .percent(value)
        YGNodeStyleSetPaddingPercent(ygNode, edge.ygValue, value)
        markLayoutDirtyHint()
    }

    public func setBorder(_ value: Float, edge: Edge = .all) {
        guard borderStyles[edge] != value else { return }
        borderStyles[edge] = value
        YGNodeStyleSetBorder(ygNode, edge.ygValue, value)
        markLayoutDirtyHint()
    }

    // MARK: - Gap

    public func setGap(_ value: Float, gutter: Gutter = .all) {
        guard gapStyles[gutter] != .points(value) else { return }
        gapStyles[gutter] = .points(value)
        YGNodeStyleSetGap(ygNode, gutter.ygValue, value)
        markLayoutDirtyHint()
    }

    public func setGapPercent(_ value: Float, gutter: Gutter = .all) {
        guard gapStyles[gutter] != .percent(value) else { return }
        gapStyles[gutter] = .percent(value)
        YGNodeStyleSetGapPercent(ygNode, gutter.ygValue, value)
        markLayoutDirtyHint()
    }

    // MARK: - Box sizing

    public var boxSizing: BoxSizing = .borderBox {
        didSet {
            guard oldValue != boxSizing else { return }
            YGNodeStyleSetBoxSizing(ygNode, boxSizing.ygValue)
            markLayoutDirtyHint()
        }
    }

    // MARK: - Layout calculation

    /// Run Yoga layout from this node as the root.
    ///
    /// - Parameters:
    ///   - availableWidth: Container width (`Float.nan` = unconstrained).
    ///   - availableHeight: Container height (`Float.nan` = unconstrained).
    ///   - direction: Layout direction (default `.ltr`).
    public func calculateLayout(
        availableWidth: Float = Float.nan,
        availableHeight: Float = Float.nan,
        direction: Direction = .ltr
    ) {
        YGNodeCalculateLayout(ygNode, availableWidth, availableHeight, direction.ygValue)
        clearLayoutDirtyHints()
    }

    /// True when this node or any descendant still needs a Yoga layout pass.
    public var subtreeIsDirty: Bool {
        subtreeLayoutDirtyHint || YGNodeIsDirty(ygNode)
    }

    // MARK: - Layout readback

    /// The computed rectangle. Valid only after `calculateLayout()` has been called.
    public var frame: CGRect {
        CGRect(
            x: Double(YGNodeLayoutGetLeft(ygNode)),
            y: Double(YGNodeLayoutGetTop(ygNode)),
            width: Double(YGNodeLayoutGetWidth(ygNode)),
            height: Double(YGNodeLayoutGetHeight(ygNode))
        )
    }

    // MARK: - Measure func (for leaf nodes such as Text)

    /// How the parent has constrained the measurement.
    public enum MeasureMode {
        case undefined  // no constraint
        case exactly    // must be exactly this size
        case atMost     // up to this size

        init(_ ygMode: YGMeasureMode) {
            switch ygMode {
            case .exactly: self = .exactly
            case .atMost:  self = .atMost
            default:       self = .undefined
            }
        }
    }

    /// Closure invoked by Yoga when the node needs intrinsic measurement.
    /// `width`/`height` may be `Float.nan` when the corresponding mode is
    /// `.undefined`. Return the natural size.
    public typealias MeasureFunc = (Float, MeasureMode, Float, MeasureMode) -> CGSize

    private var measureClosure: MeasureFunc?

    fileprivate var _measureClosure: MeasureFunc? { measureClosure }

    /// Sets a measure callback for leaf nodes (e.g. Text). Calling `nil` clears it.
    public func setMeasureFunc(_ closure: MeasureFunc?) {
        let hadMeasureFunc = measureClosure != nil
        self.measureClosure = closure
        if closure == nil {
            guard hadMeasureFunc else { return }
            YGNodeSetMeasureFunc(ygNode, nil)
            YGNodeSetContext(ygNode, nil)
            markLayoutDirtyHint()
            return
        }
        guard !hadMeasureFunc else { return }
        YGNodeSetContext(ygNode, Unmanaged.passUnretained(self).toOpaque())
        YGNodeSetMeasureFunc(ygNode, layoutNodeMeasureTrampoline)
        markLayoutDirtyHint()
    }

    /// Mark this node's measurement as stale (call after content changes).
    /// Yoga only permits this on leaf nodes that own a measure callback;
    /// callers should guard with `hasMeasureFunc` when applying generic
    /// modifiers.
    public func markDirty() {
        YGNodeMarkDirty(ygNode)
        markLayoutDirtyHint()
    }

    /// True iff this node has a custom measure callback installed via
    /// `setMeasureFunc`. Use to gate `markDirty()` from generic modifiers.
    public var hasMeasureFunc: Bool { measureClosure != nil }

    private func applyWidthStyle(_ style: LayoutStyleValue) {
        guard widthStyle != style else { return }
        widthStyle = style
        switch style {
        case .points(let value):
            YGNodeStyleSetWidth(ygNode, value)
        case .percent(let value):
            YGNodeStyleSetWidthPercent(ygNode, value)
        case .auto:
            YGNodeStyleSetWidthAuto(ygNode)
        }
        markLayoutDirtyHint()
    }

    private func applyHeightStyle(_ style: LayoutStyleValue) {
        guard heightStyle != style else { return }
        heightStyle = style
        switch style {
        case .points(let value):
            YGNodeStyleSetHeight(ygNode, value)
        case .percent(let value):
            YGNodeStyleSetHeightPercent(ygNode, value)
        case .auto:
            YGNodeStyleSetHeightAuto(ygNode)
        }
        markLayoutDirtyHint()
    }

    private func markLayoutDirtyHint() {
        guard !subtreeLayoutDirtyHint else { return }
        subtreeLayoutDirtyHint = true
        parent?.markLayoutDirtyHint()
    }

    private func clearLayoutDirtyHints() {
        guard subtreeLayoutDirtyHint else { return }
        subtreeLayoutDirtyHint = false
        for child in children {
            if child.subtreeLayoutDirtyHint {
                child.clearLayoutDirtyHints()
            }
        }
    }
}

/// Trampoline that bridges Yoga's C measure callback to the Swift closure
/// stored on `LayoutNode`. Looked up via `YGNodeGetContext`.
private let layoutNodeMeasureTrampoline: @convention(c) (
    YGNodeConstRef?, Float, YGMeasureMode, Float, YGMeasureMode
) -> YGSize = { node, width, widthMode, height, heightMode in
    guard let raw = YGNodeGetContext(node) else {
        return YGSize(width: 0, height: 0)
    }
    let layoutNode = Unmanaged<LayoutNode>.fromOpaque(raw).takeUnretainedValue()
    guard let closure = layoutNode._measureClosure else {
        return YGSize(width: 0, height: 0)
    }
    let size = closure(width, LayoutNode.MeasureMode(widthMode),
                       height, LayoutNode.MeasureMode(heightMode))
    return YGSize(width: Float(size.width), height: Float(size.height))
}
