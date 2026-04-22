import CYoga
import CoreGraphics

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

    /// Side table for style metadata that affects measurement but is not part
    /// of Yoga's native style surface.
    public var attachments: [String: Any] = [:]

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
        children.append(child)
    }

    public func removeChild(_ child: LayoutNode) {
        YGNodeRemoveChild(ygNode, child.ygNode)
        children.removeAll { $0 === child }
    }

    // MARK: - Style setters (container)

    public var direction: Direction = .inherit {
        didSet { YGNodeStyleSetDirection(ygNode, direction.ygValue) }
    }

    public var flexDirection: FlexDirection = .column {
        didSet { YGNodeStyleSetFlexDirection(ygNode, flexDirection.ygValue) }
    }

    public var alignItems: Align = .stretch {
        didSet { YGNodeStyleSetAlignItems(ygNode, alignItems.ygValue) }
    }

    public var alignContent: Align = .flexStart {
        didSet { YGNodeStyleSetAlignContent(ygNode, alignContent.ygValue) }
    }

    public var justifyContent: Justify = .flexStart {
        didSet { YGNodeStyleSetJustifyContent(ygNode, justifyContent.ygValue) }
    }

    public var flexWrap: Wrap = .noWrap {
        didSet { YGNodeStyleSetFlexWrap(ygNode, flexWrap.ygValue) }
    }

    public var overflow: Overflow = .visible {
        didSet { YGNodeStyleSetOverflow(ygNode, overflow.ygValue) }
    }

    public var display: Display = .flex {
        didSet { YGNodeStyleSetDisplay(ygNode, display.ygValue) }
    }

    // MARK: - Style setters (child)

    public var alignSelf: Align = .auto {
        didSet { YGNodeStyleSetAlignSelf(ygNode, alignSelf.ygValue) }
    }

    public var positionType: PositionType = .relative {
        didSet { YGNodeStyleSetPositionType(ygNode, positionType.ygValue) }
    }

    public var flex: Float = 0 {
        didSet { YGNodeStyleSetFlex(ygNode, flex) }
    }

    public var flexGrow: Float = 0 {
        didSet { YGNodeStyleSetFlexGrow(ygNode, flexGrow) }
    }

    public var flexShrink: Float = 0 {
        didSet { YGNodeStyleSetFlexShrink(ygNode, flexShrink) }
    }

    // MARK: - Flex basis

    public func setFlexBasis(_ value: Float) {
        YGNodeStyleSetFlexBasis(ygNode, value)
    }

    public func setFlexBasisPercent(_ value: Float) {
        YGNodeStyleSetFlexBasisPercent(ygNode, value)
    }

    public func setFlexBasisAuto() {
        YGNodeStyleSetFlexBasisAuto(ygNode)
    }

    // MARK: - Dimensions

    public var width: Float? {
        didSet {
            if let w = width { YGNodeStyleSetWidth(ygNode, w) }
            else { YGNodeStyleSetWidthAuto(ygNode) }
        }
    }

    public var minWidth: Float? {
        didSet {
            if let w = minWidth { YGNodeStyleSetMinWidth(ygNode, w) }
            else { YGNodeStyleSetMinWidth(ygNode, .nan) }
        }
    }

    public func setWidthPercent(_ value: Float) {
        YGNodeStyleSetWidthPercent(ygNode, value)
    }

    public var height: Float? {
        didSet {
            if let h = height { YGNodeStyleSetHeight(ygNode, h) }
            else { YGNodeStyleSetHeightAuto(ygNode) }
        }
    }

    public var minHeight: Float? {
        didSet {
            if let h = minHeight { YGNodeStyleSetMinHeight(ygNode, h) }
            else { YGNodeStyleSetMinHeight(ygNode, .nan) }
        }
    }

    public func setHeightPercent(_ value: Float) {
        YGNodeStyleSetHeightPercent(ygNode, value)
    }

    // MARK: - Position / Margin / Padding / Border

    public func setPosition(_ value: Float, edge: Edge) {
        YGNodeStyleSetPosition(ygNode, edge.ygValue, value)
    }

    public func setPositionPercent(_ value: Float, edge: Edge) {
        YGNodeStyleSetPositionPercent(ygNode, edge.ygValue, value)
    }

    public func setPositionAuto(edge: Edge) {
        YGNodeStyleSetPositionAuto(ygNode, edge.ygValue)
    }

    public func setMargin(_ value: Float, edge: Edge = .all) {
        YGNodeStyleSetMargin(ygNode, edge.ygValue, value)
    }

    public func setMarginPercent(_ value: Float, edge: Edge = .all) {
        YGNodeStyleSetMarginPercent(ygNode, edge.ygValue, value)
    }

    public func setMarginAuto(edge: Edge = .all) {
        YGNodeStyleSetMarginAuto(ygNode, edge.ygValue)
    }

    public func setPadding(_ value: Float, edge: Edge = .all) {
        YGNodeStyleSetPadding(ygNode, edge.ygValue, value)
    }

    public func setPaddingPercent(_ value: Float, edge: Edge = .all) {
        YGNodeStyleSetPaddingPercent(ygNode, edge.ygValue, value)
    }

    public func setBorder(_ value: Float, edge: Edge = .all) {
        YGNodeStyleSetBorder(ygNode, edge.ygValue, value)
    }

    // MARK: - Gap

    public func setGap(_ value: Float, gutter: Gutter = .all) {
        YGNodeStyleSetGap(ygNode, gutter.ygValue, value)
    }

    public func setGapPercent(_ value: Float, gutter: Gutter = .all) {
        YGNodeStyleSetGapPercent(ygNode, gutter.ygValue, value)
    }

    // MARK: - Box sizing

    public var boxSizing: BoxSizing = .borderBox {
        didSet { YGNodeStyleSetBoxSizing(ygNode, boxSizing.ygValue) }
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
    }

    /// True when this node or any descendant still needs a Yoga layout pass.
    public var subtreeIsDirty: Bool {
        if YGNodeIsDirty(ygNode) {
            return true
        }
        return children.contains { $0.subtreeIsDirty }
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
            case YGMeasureMode.exactly: self = .exactly
            case YGMeasureMode.atMost:  self = .atMost
            default:                    self = .undefined
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
        self.measureClosure = closure
        if closure == nil {
            YGNodeSetMeasureFunc(ygNode, nil)
            YGNodeSetContext(ygNode, nil)
            return
        }
        YGNodeSetContext(ygNode, Unmanaged.passUnretained(self).toOpaque())
        YGNodeSetMeasureFunc(ygNode, layoutNodeMeasureTrampoline)
    }

    /// Mark this node's measurement as stale (call after content changes).
    /// Yoga only permits this on leaf nodes that own a measure callback;
    /// callers should guard with `hasMeasureFunc` when applying generic
    /// modifiers.
    public func markDirty() {
        YGNodeMarkDirty(ygNode)
    }

    /// True iff this node has a custom measure callback installed via
    /// `setMeasureFunc`. Use to gate `markDirty()` from generic modifiers.
    public var hasMeasureFunc: Bool { measureClosure != nil }
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
