import Foundation
import GuavaUIRuntime

/// Vertical list whose rows can be reordered with a drag handle or the
/// keyboard. The caller owns the order: `onMove` receives the source index and
/// the final index after the row is removed, and is expected to mutate the
/// backing collection.
///
/// The handle is a 44pt-wide target and is the only drag surface, so row
/// content keeps its own buttons and taps. While dragging, a 2pt accent line
/// marks the insertion boundary; Escape cancels without calling `onMove`.
/// Keyboard users focus the handle and use Up/Down; assistive clients get the
/// same operations through increment/decrement.
public struct ReorderableList<Data: RandomAccessCollection, ID: Hashable, RowContent: View>: View {
    public let data: Data
    public let id: KeyPath<Data.Element, ID>
    /// Authored logical row height, before text scaling and the touch floor.
    public let rowHeight: Float
    /// Authored logical row spacing, before text scaling.
    public let rowSpacing: Float
    public let isEnabled: Bool
    /// Called with `(from, to)`, where `to` is the final index after removal.
    public let onMove: (Int, Int) -> Void
    public let rowLabel: (Data.Element) -> String
    public let rowContent: (Data.Element, Bool) -> RowContent

    @State private var draggingID: ID?
    @State private var dropBoundary: Int?
    @State private var viewportWidth: Float = 0

    public init(_ data: Data,
                id: KeyPath<Data.Element, ID>,
                rowHeight: Float = 36,
                rowSpacing: Float = 0,
                isEnabled: Bool = true,
                rowLabel: @escaping (Data.Element) -> String = { _ in "" },
                onMove: @escaping (Int, Int) -> Void,
                @ViewBuilder rowContent: @escaping (Data.Element, Bool) -> RowContent) {
        self.data = data
        self.id = id
        self.rowHeight = max(1, rowHeight)
        self.rowSpacing = max(0, rowSpacing)
        self.isEnabled = isEnabled
        self.rowLabel = rowLabel
        self.onMove = onMove
        self.rowContent = rowContent
    }

    public var body: some View {
        _ReorderableListHost { surface, scaler in
            AnyView(content(surface: surface, scaler: scaler))
        }
    }

    private func content(surface: UIEnvironment, scaler: TextScaler) -> some View {
        let elements = Array(data)
        let height = max(scaler.scale(rowHeight),
                         surface.input.contains(.touch) ? surface.minimumControlExtent : 0)
        let spacing = scaler.scale(rowSpacing)
        let rowStride = height + spacing
        let contentHeight = max(0, Float(elements.count) * rowStride - spacing)
        let width = max(1, viewportWidth)
        return Box(direction: .column, alignItems: .stretch, spacing: 0) {
            ScrollView(.vertical, scrollbarGutter: .stable,
                       onViewportChange: { viewport in
                let next = Float(viewport.size.width)
                if abs(next - viewportWidth) > 0.5 { viewportWidth = next }
            }) {
                Box(direction: .column, alignItems: .stretch, spacing: spacing) {
                    for index in elements.indices {
                        AnyView(row(elements[index], index: index, elements: elements,
                                    height: height, spacing: spacing))
                    }
                }
                .frame(width: .points(width), height: .points(max(1, contentHeight)))
                .overlay(alignment: .topLeading) {
                    if let boundary = visibleDropBoundary(elements: elements), elements.count > 1 {
                        Box {
                            dropIndicator(boundary: boundary, count: elements.count,
                                          rowStride: rowStride, contentHeight: contentHeight)
                        }
                        .frame(width: .points(width), height: .points(max(1, contentHeight)))
                    }
                }
            }
            .flex(1, shrink: 1, basis: 0)
        }
        .flex(1, shrink: 1, basis: 0)
    }

    private func row(_ element: Data.Element, index: Int, elements: [Data.Element],
                     height: Float, spacing: Float) -> some View {
        let elementID = element[keyPath: id]
        let dragging = draggingID == elementID
        let rowStride = height + spacing
        return Row(alignment: .center, spacing: 4) {
            Box(direction: .column, alignItems: .stretch) {
                rowContent(element, dragging)
            }
            .flex(1, shrink: 1, basis: 0)
            .frame(minWidth: 0)
            .clipped()
            _ReorderHandle(index: index, count: elements.count,
                           label: handleLabel(element, index: index),
                           isEnabled: isEnabled, isDragging: dragging,
                           rowHeight: height,
                           onStart: { beginDrag(element, index: index) },
                           onDelta: { delta in updateDrag(delta: delta, elements: elements, contentStride: rowStride) },
                           onEnd: { finishDrag(elements: elements) },
                           onCancel: cancelDrag,
                           onStep: { step in move(index: index, by: step, elements: elements) })
        }
        .frame(height: height)
        .background(dragging ? SemanticColorRef.stateLayerPressed : .clear)
        .cornerRadius(6)
        .clipped()
        .id(elementID)
    }

    private func dropIndicator(boundary: Int, count: Int,
                               rowStride: Float, contentHeight: Float) -> some View {
        let y = boundary >= count ? max(0, contentHeight - 2) : Float(boundary) * rowStride - 1
        return Box {}.frame(height: 2)
            .background(.accent)
            .cornerRadius(1)
            .absolutePosition(left: 8, top: y, right: 8)
            .accessibilityHidden()
            .debugName("reorder-drop-indicator")
    }

    private func beginDrag(_ element: Data.Element, index: Int) {
        guard isEnabled else { return }
        draggingID = element[keyPath: id]
        dropBoundary = index
    }

    private func updateDrag(delta: CGFloat, elements: [Data.Element], contentStride: Float) {
        guard let draggingID,
              let source = elements.firstIndex(where: { $0[keyPath: id] == draggingID }) else { return }
        let rowStride = max(1, contentStride)
        let offset = Int((Float(delta) / rowStride).rounded())
        dropBoundary = min(elements.count, max(0, source + offset))
    }

    private func finishDrag(elements: [Data.Element]) {
        defer { draggingID = nil; dropBoundary = nil }
        guard let draggingID, let boundary = dropBoundary,
              let source = elements.firstIndex(where: { $0[keyPath: id] == draggingID }) else { return }
        let destination = boundary > source ? boundary - 1 : boundary
        guard destination != source else { return }
        onMove(source, destination)
    }

    private func cancelDrag() {
        draggingID = nil
        dropBoundary = nil
    }

    private func move(index: Int, by delta: Int, elements: [Data.Element]) {
        guard isEnabled, !elements.isEmpty else { return }
        let destination = min(elements.count - 1, max(0, index + delta))
        guard destination != index else { return }
        onMove(index, destination)
    }

    private func visibleDropBoundary(elements: [Data.Element]) -> Int? {
        guard let draggingID, let boundary = dropBoundary,
              let source = elements.firstIndex(where: { $0[keyPath: id] == draggingID }) else { return nil }
        let destination = boundary > source ? boundary - 1 : boundary
        guard destination != source else { return nil }
        return boundary
    }

    private func handleLabel(_ element: Data.Element, index: Int) -> String {
        let title = rowLabel(element)
        return title.isEmpty ? "Reorder item \(index + 1) of \(data.count)"
            : "Reorder \(title), position \(index + 1) of \(data.count)"
    }
}

// MARK: - _ReorderHandle

private enum _ReorderHandleKeys {
    static let active = "__reorder.active"
    static let startY = "__reorder.startY"
    static let hovered = "__reorder.hovered"
}

/// Drag/focus handle behind one reorderable row. Interaction state lives on
/// the node so a parent recompose mid-drag keeps the pointer transaction.
private struct _ReorderHandle: _PrimitiveView {
    let index: Int
    let count: Int
    let label: String
    let isEnabled: Bool
    let isDragging: Bool
    let rowHeight: Float
    let onStart: () -> Void
    let onDelta: (CGFloat) -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void
    let onStep: (Int) -> Void

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        return node
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.width = 44
        layout.height = rowHeight
        layout.flexShrink = 0
        layout.alignItems = .center
        layout.justifyContent = .center
        return layout
    }

    func _updateNode(_ node: Node) {
        node.applyTouchControlExtent()
        node.isFocusable = isEnabled
        node.attachments[LayoutDebugAttachmentKey.debugName] = "reorder-handle-\(index)"
        node.cornerRadius = 6
        node.cursor = isEnabled ? .pointer : nil
        node.accessibility = AccessibilitySemantics(.slider) {
            $0.label = label
            $0.value = "Position \(index + 1) of \(count)"
            $0.help = "Drag the handle, or use Up and Down to move this row."
            $0.state.isEnabled = isEnabled
            $0.state.isSelected = isDragging
        }
        node.accessibilityActions.increment = isEnabled ? { onStep(1) } : nil
        node.accessibilityActions.decrement = isEnabled ? { onStep(-1) } : nil

        let applyBackground: (Bool) -> Void = { hovered in
            let active = node.attachments[_ReorderHandleKeys.active] as? Bool == true
            node.backgroundColor = active ? node.theme.colors.stateLayerPressed
                : (hovered && isEnabled ? node.theme.colors.stateLayerHover : .clear)
        }
        applyBackground(node.attachments[_ReorderHandleKeys.hovered] as? Bool == true)
        guard let registry = InteractionRegistryHolder.current else { return }
        registry.setHover(node) { phase in
            let hovered = phase == .enter && node.supportsControlHover
            node.attachments[_ReorderHandleKeys.hovered] = hovered
            applyBackground(hovered)
        }
        registry.setPointer(node) { event, phase, _ in
            guard isEnabled, event.button == .left else { return .ignored }
            switch phase {
            case .down:
                node.attachments[_ReorderHandleKeys.active] = true
                node.attachments[_ReorderHandleKeys.startY] = event.y
                PointerCaptureHolder.current?.acquire(node)
                applyBackground(true)
                onStart()
                return .handled
            case .up:
                guard node.attachments[_ReorderHandleKeys.active] as? Bool == true else {
                    return .ignored
                }
                node.attachments[_ReorderHandleKeys.active] = false
                node.attachments.removeValue(forKey: _ReorderHandleKeys.startY)
                if PointerCaptureHolder.current?.target === node {
                    PointerCaptureHolder.current?.release()
                }
                applyBackground(node.attachments[_ReorderHandleKeys.hovered] as? Bool == true)
                onEnd()
                return .handled
            }
        }
        registry.setMotion(node) { event, _ in
            guard node.attachments[_ReorderHandleKeys.active] as? Bool == true,
                  let start = node.attachments[_ReorderHandleKeys.startY] as? Float else { return .ignored }
            onDelta(CGFloat(event.y - start))
            return .handled
        }
        registry.setKey(node) { event, phase in
            guard phase != .capture, isEnabled else { return .ignored }
            switch event.scancode {
            case Scancode.arrowUp:
                onStep(-1)
                return .handled
            case Scancode.arrowDown:
                onStep(1)
                return .handled
            case Scancode.escape:
                guard node.attachments[_ReorderHandleKeys.active] as? Bool == true else {
                    return .ignored
                }
                node.attachments[_ReorderHandleKeys.active] = false
                node.attachments.removeValue(forKey: _ReorderHandleKeys.startY)
                if PointerCaptureHolder.current?.target === node {
                    PointerCaptureHolder.current?.release()
                }
                onCancel()
                return .handled
            default:
                return .ignored
            }
        }
    }

    var _children: [any View] {
        [Icon(UIIcons.Action.grip, size: .small, color: .onSurfaceMuted)
            .iconScaling(.fixed)
            .accessibilityHidden()]
    }
}

/// Root passthrough for the reorderable list. It owns a flex layout node so a
/// caller's `.frame(height:)`/`.flex()` reaches the inner ScrollView; the
/// surface and text scaler are read from the node, like `SelectionKeyHost`.
private struct _ReorderableListHost: _PrimitiveView {
    let content: (UIEnvironment, TextScaler) -> AnyView

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column
        layout.alignItems = .stretch
        layout.flexGrow = 1
        layout.flexShrink = 1
        return layout
    }

    func _updateNode(_ node: Node) {}

    func _children(for node: Node) -> [any View] {
        [content(node.compositionValue(of: SurfaceEnvironment.key), node.textScaler)]
    }
}
