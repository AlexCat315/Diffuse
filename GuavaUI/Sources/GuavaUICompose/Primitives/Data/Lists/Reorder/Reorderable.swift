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
    @State private var drag = ReorderDragSession()

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
                drag.scrollY = Float(viewport.offset.y); drag.viewportHeight = Float(viewport.size.height)
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
            if let draggingID, let element = elements.first(where: { $0[keyPath: id] == draggingID }) {
                // An absolute sibling covering the viewport: outside the flow, never hit.
                ReorderPreviewHost(session: drag, content: preview(element, width: width, height: height))
                    .absolutePosition(left: 0, top: 0, right: 0, bottom: 0)
                    .allowsHitTesting(false)
            }
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
                           onStart: { beginDrag(element, index: index, rowStride: rowStride, height: height) },
                           onDelta: { travel, scrolled in
                               updateDrag(travel: travel, scrolled: scrolled, elements: elements, contentStride: rowStride)
                           },
                           onEnd: { finishDrag(elements: elements) },
                           onCancel: cancelDrag,
                           onStep: { step in move(index: index, by: step, elements: elements) })
        }
        .frame(height: height)
        // The lifted copy follows the pointer; the row stays as a placeholder.
        .opacity(dragging ? 0.35 : 1)
        .cornerRadius(6)
        .clipped()
        .id(elementID)
    }

    /// The lifted row: the same content on a raised surface with its grip,
    /// so the dragged item stays visible even after it scrolls out of view.
    private func preview(_ element: Data.Element, width: Float, height: Float) -> some View {
        ThemeReader { theme in
            Row(alignment: .center, spacing: 4) {
                Box(direction: .column, alignItems: .stretch) { rowContent(element, true) }
                    .flex(1, shrink: 1, basis: 0).frame(minWidth: 0).clipped()
                Box(direction: .row, alignItems: .center, justifyContent: .center) {
                    Icon(UIIcons.Action.grip, size: .small, color: .onSurfaceMuted).iconScaling(.fixed)
                }.frame(width: 44, height: height)
            }
            .frame(width: .points(width), height: .points(height))
            .background(.surface)
            .cornerRadius(6)
            .border(theme.colors.accent.multipliedAlpha(0.35), width: 1)
            .shadow(color: theme.elevation.medium.color ?? .clear, offsetY: 4, blur: 12)
            .accessibilityHidden()
            .debugName("reorder-preview")
        }
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

    private func beginDrag(_ element: Data.Element, index: Int, rowStride: Float, height: Float) {
        guard isEnabled else { return }
        drag.begin(rowTopInContent: Float(index) * rowStride, rowHeight: height)
        draggingID = element[keyPath: id]
        dropBoundary = index
    }

    /// `travel` is pointer movement; `scrolled` is automatic scrolling since
    /// the drag began. Their sum is the position in content coordinates.
    private func updateDrag(travel: CGFloat, scrolled: CGFloat, elements: [Data.Element], contentStride: Float) {
        drag.move(travel: Float(travel))
        let delta = travel + scrolled
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
