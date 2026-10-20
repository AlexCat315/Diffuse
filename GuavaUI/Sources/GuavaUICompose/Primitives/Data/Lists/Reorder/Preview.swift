import Foundation
import GuavaUIRuntime

/// Transient drag geometry shared by the handle, the list and the floating
/// preview. Pointer moves update it in place; only starting and ending a
/// drag recompose the list.
final class ReorderDragSession {
    /// Latest scroll offset and height of the list viewport.
    var scrollY: Float = 0
    var viewportHeight: Float = 0
    /// Dragged row's top in viewport coordinates when the drag began.
    private var startTop: Float = 0
    private var rowHeight: Float = 0
    private(set) var previewTop: Float = 0
    weak var previewNode: Node?

    func begin(rowTopInContent: Float, rowHeight: Float) {
        self.rowHeight = rowHeight
        startTop = rowTopInContent - scrollY
        move(travel: 0)
    }

    /// Follows the pointer, staying inside the viewport so the preview rests
    /// at the edge while automatic scrolling moves the content beneath it.
    func move(travel: Float) {
        previewTop = min(max(0, viewportHeight - rowHeight), max(0, startTop + travel))
        apply()
    }

    func apply() {
        guard let previewNode else { return }
        let offset = CGPoint(x: 0, y: -CGFloat(previewTop))
        if previewNode.contentOffset != offset { previewNode.contentOffset = offset }
    }
}

/// Covers the list viewport and paints the lifted row at the session's
/// position through its content offset, so following the pointer neither
/// relayouts nor recomposes. It never takes input.
struct ReorderPreviewHost<Content: View>: _PrimitiveView {
    let session: ReorderDragSession
    let content: Content

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.clipsToBounds = true
        return node
    }
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column; layout.alignItems = .stretch
        return layout
    }
    func _updateNode(_ node: Node) {
        session.previewNode = node
        session.apply()
    }
    var _children: [any View] { [content] }
}
