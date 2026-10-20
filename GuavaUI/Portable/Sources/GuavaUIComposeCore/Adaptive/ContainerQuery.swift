import Foundation
import GuavaUIScene

/// Reports the content-box size of its own subtree after every layout pass,
/// so content can adapt to the space actually available to it — a container
/// query rather than a window query. The selected branch of a candidate
/// layout only sees the proposal; this reader sees the measured result.
///
/// Measurement runs after the composition that built this view, so the first
/// build receives `.zero` and the next frame publishes the measured size.
/// A size is published only when it changes by at least 0.5 points.
/// The reader fills its parent's available width, so changing content does
/// not determine the width used to select that content.
///
/// ```swift
/// ContainerSizeReader { size in
///     size.width < 300
///         ? AnyView(CompactCard())
///         : AnyView(WideCard())
/// }
/// ```
///
/// Children keep ordinary layout semantics. Height remains content driven;
/// use a frame or flex allocation to query a constrained height. An intrinsic
/// parent must itself have a bounded width for width-based queries to settle.
public struct ContainerSizeReader<Content: View>: View {
    @State private var size: CGSize = .zero
    private let content: (CGSize) -> Content

    public init(@ViewBuilder content: @escaping (CGSize) -> Content) {
        self.content = content
    }

    public var body: some View {
        _ContainerSizeProbe(reported: $size) { content(size) }
    }
}

/// Measurement state for one probe node. Lives in `Node.attachments` so it
/// survives recomposition without the layout hook being reinstalled.
private final class ContainerSizeMeasurement {
    /// Frame changes below this magnitude are treated as the same size.
    static let tolerance: CGFloat = 0.5

    var reported: Binding<CGSize>
    private(set) var lastReported: CGSize = .zero

    init(reported: Binding<CGSize>) {
        self.reported = reported
    }

    func update(_ node: Node) {
        let padding = node.layoutNode?.resolvedPadding ?? LayoutInsets(top: 0, right: 0, bottom: 0, left: 0)
        let border = node.layoutNode?.resolvedBorder ?? LayoutInsets(top: 0, right: 0, bottom: 0, left: 0)
        let measured = CGSize(width: max(0, node.frame.width - CGFloat(padding.left + padding.right + border.left + border.right)),
                              height: max(0, node.frame.height - CGFloat(padding.top + padding.bottom + border.top + border.bottom)))
        guard measured.width.isFinite, measured.height.isFinite else { return }
        guard abs(measured.width - lastReported.width) >= Self.tolerance
                || abs(measured.height - lastReported.height) >= Self.tolerance else { return }
        lastReported = measured
        reported.wrappedValue = measured
    }
}

/// Pass-through node that publishes its post-layout frame into the
/// measurement state. Reports after every layout pass; the one-time hook
/// chain keeps repeated recompositions from stacking obsolete callbacks.
private let containerSizeMeasurementKey = "__guavaui_container_size_measurement"

private struct _ContainerSizeProbe<Content: View>: _PrimitiveView {
    let reported: Binding<CGSize>
    let content: Content

    init(reported: Binding<CGSize>, @ViewBuilder content: () -> Content) {
        self.reported = reported
        self.content = content()
    }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {
        if let measurement = node.attachments[containerSizeMeasurementKey] as? ContainerSizeMeasurement {
            measurement.reported = reported
            return
        }
        let measurement = ContainerSizeMeasurement(reported: reported)
        node.attachments[containerSizeMeasurementKey] = measurement
        let previous = node.layoutDidUpdate
        node.layoutDidUpdate = { node in
            previous?(node)
            (node.attachments[containerSizeMeasurementKey] as? ContainerSizeMeasurement)?.update(node)
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.setWidthPercent(100)
        layout.alignItems = .stretch
        return layout
    }
    func _updateLayout(_ layout: LayoutNode) {}

    var _children: [any View] { [content] }
}
