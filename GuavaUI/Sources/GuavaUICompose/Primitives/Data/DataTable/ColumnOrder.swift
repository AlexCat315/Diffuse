import Foundation
import GuavaUIRuntime

/// Display order of authored columns. Unknown IDs are ignored and columns
/// missing from the order keep their authored position after ordered ones,
/// so adding a column never requires migrating a saved order.
enum DataTableColumnOrder {
    static func apply<Record>(_ order: [String], to columns: [TableColumn<Record>]) -> [TableColumn<Record>] {
        guard !order.isEmpty else { return columns }
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return columns.enumerated().sorted { lhs, rhs in
            switch (rank[lhs.element.id], rank[rhs.element.id]) {
            case let (a?, b?): a < b
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// Moves `source` next to `target` in the full order (hidden columns keep
    /// their relative places), before it when moving left, after it otherwise.
    static func move(_ source: String, to target: String, in order: [String]) -> [String] {
        guard source != target, let from = order.firstIndex(of: source), let to = order.firstIndex(of: target) else { return order }
        var result = order
        result.remove(at: from)
        let anchor = result.firstIndex(of: target)!
        result.insert(source, at: to > from ? anchor + 1 : anchor)
        return result
    }

    /// The presented column whose span contains the dragged column's center.
    static func target(source: Int, offset: Float, geometry: DataTableColumnGeometry) -> Int {
        guard geometry.widths.indices.contains(source) else { return source }
        let center = geometry.starts[source] + geometry.widths[source] / 2 + offset
        return geometry.starts.lastIndex { $0 <= center } ?? 0
    }
}

/// Observes a header drag in the capture phase, so a sortable header's own
/// button still handles plain clicks. Past a small threshold the drag takes
/// over: the button never receives the release, and the column moves.
struct DataTableHeaderDragHost<Content: View>: _PrimitiveView {
    let isEnabled: Bool
    let onChange: (Float?) -> Void
    let onDrop: (Float) -> Void
    let content: Content

    private final class Press { var startX: Float; var isDragging = false; init(_ x: Float) { startX = x } }
    private static var key: String { "dataTable.headerDrag" }

    func _makeNode() -> Node { let node = Node(); node.isHitTestable = true; return node }
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode(); layout.flexDirection = .row; layout.alignItems = .stretch; return layout
    }
    func _updateNode(_ node: Node) {
        guard isEnabled, let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node); return
        }
        let key = Self.key
        registry.setPointer(node) { [weak node] event, phase, eventPhase in
            guard let node, event.button == .left else { return .ignored }
            switch phase {
            case .down:
                switch eventPhase {
                case .capture:
                    node.attachments[key] = Press(event.x)
                    return .ignored
                case .target:
                    // A plain title has no control of its own: own the pointer.
                    node.attachments[key] = Press(event.x)
                    PointerCaptureHolder.current?.acquire(node)
                    return .handled
                case .bubble:
                    return .ignored
                }
            case .up:
                guard let press = node.attachments.removeValue(forKey: key) as? Press else { return .ignored }
                if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
                guard press.isDragging else { return .ignored }
                onDrop(event.x - press.startX)
                return .handled
            }
        }
        registry.setMotion(node) { [weak node] event, eventPhase in
            guard let node, let press = node.attachments[key] as? Press else { return .ignored }
            // A resize grip owns its own drag; it never reorders.
            if !press.isDragging, let captured = PointerCaptureHolder.current?.target, captured !== node,
               captured.cursor == .resizeHorizontal {
                node.attachments.removeValue(forKey: key); return .ignored
            }
            let offset = event.x - press.startX
            if !press.isDragging {
                guard abs(offset) >= 6 else { return .ignored }
                press.isDragging = true
                // Take the pointer from the header button so its release does not sort.
                PointerCaptureHolder.current?.acquire(node)
            }
            onChange(offset)
            return eventPhase == .capture ? .handled : .ignored
        }
        registry.setKey(node) { [weak node] event, _ in
            guard let node, event.scancode == Scancode.escape, let press = node.attachments[key] as? Press, press.isDragging else { return .ignored }
            node.attachments.removeValue(forKey: key)
            if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
            onChange(nil)
            return .handled
        }
    }
    var _children: [any View] { [content] }
}

extension DataTable {
    /// Moves a presented column one place (keyboard) and keeps it focused.
    func moveColumn(at index: Int, by step: Int) -> Bool {
        let target = index + step
        guard options.isEnabled, columns.indices.contains(index), columns.indices.contains(target) else { return false }
        orderBinding.wrappedValue = DataTableColumnOrder.move(columns[index].id, to: columns[target].id, in: displayOrder)
        return true
    }

    func dropColumn(at index: Int, offset: Float, geometry: DataTableColumnGeometry) {
        session.columnDrag = nil
        let target = DataTableColumnOrder.target(source: index, offset: offset, geometry: geometry)
        guard options.isEnabled, target != index, columns.indices.contains(target) else { return }
        orderBinding.wrappedValue = DataTableColumnOrder.move(columns[index].id, to: columns[target].id, in: displayOrder)
    }

    /// Insertion line for an active header drag, in header coordinates.
    func columnDropIndicator(geometry: DataTableColumnGeometry) -> AnyView? {
        guard let drag = session.columnDrag, let source = columns.firstIndex(where: { $0.id == drag.columnID }) else { return nil }
        let target = DataTableColumnOrder.target(source: source, offset: drag.offset, geometry: geometry)
        guard target != source else { return nil }
        let boundary = target < source ? geometry.starts[target] : geometry.starts[target] + geometry.widths[target]
        let x = boundary <= geometry.frozenWidth ? boundary : boundary - Float(session.offset.x)
        return AnyView(Box {}.frame(width: 2, height: options.layout.headerHeight).background(.accent)
            .absolutePosition(left: max(0, x - 1), top: 0).accessibilityHidden().debugName("dataTable-column-drop"))
    }
}
