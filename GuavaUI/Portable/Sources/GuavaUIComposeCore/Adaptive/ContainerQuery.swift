import GuavaUIScene
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Reports the content-box size of its own subtree after every layout pass,
/// so content can adapt to the space actually available to it — a container
/// query rather than a window query. The selected branch of a candidate
/// layout only sees the proposal; this reader sees the measured result.
///
/// Measurement runs after the composition that built this view, so the first
/// build receives `.zero` and the next frame publishes the measured size.
/// A frame is published only when it moves beyond a small tolerance, so
/// layout rounding jitter cannot drive an endless recompose–relayout loop.
///
/// ```swift
/// ContainerSizeReader { size in
///     size.width < 300
///         ? AnyView(CompactCard())
///         : AnyView(WideCard())
/// }
/// ```
///
/// The node is a pass-through: children keep ordinary layout semantics and
/// the reader stretches them on the cross axis like a column `Box`. Callers
/// that need the container to fill an offered width can add
/// `.flex(1, shrink: 1)` or wrap it in a sized frame.
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
        let measured = node.frame.size
        guard measured.width.isFinite, measured.height.isFinite else { return }
        guard abs(measured.width - lastReported.width) > Self.tolerance
                || abs(measured.height - lastReported.height) > Self.tolerance else { return }
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

    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateLayout(_ layout: LayoutNode) {}

    var _children: [any View] { [content] }
}
