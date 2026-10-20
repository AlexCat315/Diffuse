import Foundation
import GuavaUIRuntime

/// Virtualizes rows whose heights are unknown until they render. Unmeasured
/// rows use the estimate; each mounted row reports its laid-out height, which
/// is cached by ID for the current width and text scale. When measurements
/// above the viewport change, the first visible row keeps its position, so
/// content does not jump while the index converges.
struct EstimatedVirtualStack<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    private let data: Data
    private let id: KeyPath<Data.Element, ID>
    private let estimate: Float
    private let spacing: Float
    private let overscan: Int
    private let scrollToIndex: Int?
    private let content: (Data.Element) -> Content
    private let generation = UUID()
    @State private var metrics = EstimatedRowMetrics<ID>()
    @State private var viewport = ScrollViewport(offset: .zero, size: .zero)
    @State private var offset = CGPoint.zero
    @State private var previousTarget: Int?
    /// Bumped when a mounted row reports a new height.
    @State private var revision = 0

    init(_ data: Data, id: KeyPath<Data.Element, ID>, estimatedRowHeight: Float,
         spacing: Float = 0, overscan: Int = 3, scrollToIndex: Int? = nil,
         @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.id = id
        self.estimate = estimatedRowHeight.isFinite ? max(1, estimatedRowHeight) : 44
        self.spacing = spacing.isFinite ? max(0, spacing) : 0
        self.overscan = max(0, overscan)
        self.scrollToIndex = scrollToIndex
        self.content = content
    }

    var body: some View {
        SurfaceReader { surface in
            TextScalerReader { scaler in scrollView(scaler: scaler, gutter: ScrollView<EmptyView>.stableGutterWidth(on: surface)) }
        }
    }

    private func scrollView(scaler: TextScaler, gutter: Float) -> some View {
        _ = revision
        let height = Double(viewport.size.height)
        let width = max(0, Float(viewport.size.width) - gutter)
        var nextOffset = metrics.synchronize(data, id: id, generation: generation, width: width, scaler: scaler,
                                             estimate: scaler.scale(estimate), spacing: spacing,
                                             offset: Double(offset.y), viewport: height)
        let rows = metrics.rows
        if scrollToIndex == nil, previousTarget != nil { previousTarget = nil }
        if let target = scrollToIndex, target != previousTarget, height > 0, rows.count > 0 {
            nextOffset = rows.reveal(target, offset: nextOffset, viewport: height)
            previousTarget = target
        }
        if Double(offset.y) != nextOffset { offset.y = CGFloat(nextOffset) }
        let range = rows.visibleRange(offset: rows.clamp(nextOffset, viewport: height),
                                      viewport: height, overscan: overscan)
        let before = rows.top(of: range.lowerBound)
        let after = max(0, rows.total - rows.top(of: range.upperBound))
        let metrics = metrics
        return ScrollView(.vertical, scrollbarGutter: .stable,
                          scrollOffset: Binding(get: { offset }, set: { if offset != $0 { offset = $0 } }),
                          onViewportChange: { if viewport != $0 { viewport = $0 } }) {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                Box {}.frame(height: Float(before)).flex(0, shrink: 0)
                range.map { index in
                    let element = data[data.index(data.startIndex, offsetBy: index)]
                    let rowID = element[keyPath: id]
                    let gap = index + 1 < rows.count ? Float(rows.spacing) : 0
                    return AnyView(EstimatedRowHost(gap: gap, onHeight: { measured in
                        if metrics.record(rowID, height: measured) { revision &+= 1 }
                    }) {
                        Box(direction: .column, alignItems: .stretch) { content(element) }
                    }
                    .padding(EdgeInsets(bottom: gap))
                    .flex(0, shrink: 0)
                    .id(rowID))
                }
                Box {}.frame(height: Float(after)).flex(0, shrink: 0)
            }
            .frame(minWidth: 0)
            .flex(0, shrink: 0)
        }
    }
}

/// Reports the natural height of one mounted row after layout.
private struct EstimatedRowHost<Content: View>: _PrimitiveView {
    /// Spacing padded below the row; excluded from the reported height.
    let gap: Float
    let onHeight: (Float) -> Void
    @ViewBuilder let content: Content
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode(); layout.flexDirection = .column; layout.alignItems = .stretch; return layout
    }
    func _updateNode(_ node: Node) {
        node.layoutDidUpdate = { node in
            let height = Float(node.frame.height) - gap
            if height > 0 { onHeight(height) }
        }
    }
    var _children: [any View] { [content] }
}

/// Measured heights by ID plus the estimate for everything else. Measurements
/// are discarded when width or text scale change, because wrapping changes.
final class EstimatedRowMetrics<ID: Hashable> {
    private var generation: UUID?
    private var width: Float = -1
    private var scaler = TextScaler.identity
    private var estimate: Float = -1
    private var spacing: Float = -1
    private var viewportHeight: Double = -1
    private var measured: [ID: Float] = [:]
    private var isDirty = false
    private(set) var rows = VariableRowIndex<ID>()

    /// Records a mounted row's height; true when the index must change.
    func record(_ id: ID, height: Float) -> Bool {
        guard abs((measured[id] ?? -1) - height) > 0.5 else { return false }
        measured[id] = height
        isDirty = true
        return true
    }

    func height(for id: ID) -> Float? { measured[id] }

    func synchronize<Data: RandomAccessCollection>(
        _ data: Data, id: KeyPath<Data.Element, ID>, generation: UUID, width: Float, scaler: TextScaler,
        estimate: Float, spacing: Float, offset: Double, viewport: Double
    ) -> Double {
        let layoutChanged = self.width != width || self.scaler != scaler
        guard isDirty || layoutChanged || self.generation != generation
                || self.estimate != estimate || self.spacing != spacing else {
            if viewportHeight != viewport { viewportHeight = viewport; return rows.clamp(offset, viewport: viewport) }
            return offset
        }
        if layoutChanged { measured.removeAll(keepingCapacity: true) }
        let anchor = rows.anchor(at: offset)
        var ids: [ID] = [], heights: [Float] = []
        ids.reserveCapacity(data.count); heights.reserveCapacity(data.count)
        for element in data {
            let rowID = element[keyPath: id]
            ids.append(rowID)
            heights.append(measured[rowID] ?? estimate)
        }
        rows.replace(ids: ids, heights: heights, spacing: spacing)
        self.generation = generation; self.width = width; self.scaler = scaler
        self.estimate = estimate; self.spacing = spacing; viewportHeight = viewport
        isDirty = false
        return anchor.map { rows.offset(for: $0, viewport: viewport) } ?? rows.clamp(offset, viewport: viewport)
    }
}
