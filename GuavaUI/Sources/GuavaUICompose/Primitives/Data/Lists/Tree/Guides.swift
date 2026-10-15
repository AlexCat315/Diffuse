import Foundation
import GuavaUIRuntime

struct TreeGuideRowSnapshot: Equatable {
    let depth: Int
    let ancestorHasNextSiblings: [Bool]
    let hasNextSibling: Bool
}

struct TreeGuideOverlayHost<Content: View>: _PrimitiveView {
    let rows: [TreeGuideRowSnapshot]
    let rowHeight: Float
    let rowSpacing: Float
    let indentation: Float
    let showsIndentGuides: Bool
    let content: Content

    private struct PaintIdentity: Equatable {
        let rows: [TreeGuideRowSnapshot]
        let rowHeight: Float
        let rowSpacing: Float
        let indentation: Float
        let showsIndentGuides: Bool
    }

    init(rows: [TreeGuideRowSnapshot],
         rowHeight: Float,
         rowSpacing: Float,
         indentation: Float,
         showsIndentGuides: Bool,
         @ViewBuilder content: () -> Content) {
        self.rows = rows
        self.rowHeight = rowHeight
        self.rowSpacing = rowSpacing
        self.indentation = indentation
        self.showsIndentGuides = showsIndentGuides
        self.content = content()
    }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {
        node.attachments["__tree_guide"] = true
        let rows = rows
        let rowHeight = rowHeight
        let rowSpacing = rowSpacing
        let indentation = indentation
        let showsIndentGuides = showsIndentGuides

        node.updateDraw(identity: PaintIdentity(rows: rows,
                                                rowHeight: rowHeight,
                                                rowSpacing: rowSpacing,
                                                indentation: indentation,
                                                showsIndentGuides: showsIndentGuides)) { [weak node] list, origin in
            guard let node,
                  showsIndentGuides,
                  rowHeight > 0,
                  indentation > 0,
                  !rows.isEmpty else {
                return
            }

            let baseX = Float(origin.x)
            let baseY = Float(origin.y)
            let rowStride = rowHeight + rowSpacing
            let centerLead: Float = {
                let whole = max(2, indentation.rounded(.down))
                return ((whole - 1) * 0.5).rounded(.down)
            }()
            let centerYLead: Float = {
                let whole = max(2, rowHeight.rounded(.down))
                return max(0, ((whole - 1) * 0.5).rounded(.down))
            }()
            let continuationExtension = max(0, rowSpacing.rounded(.up))
            let guideInk = node.theme.colors.onSurfaceMuted.multipliedAlpha(0.24 * node.opacity)
            let branchColor = guideInk
            let ancestorColor = guideInk

            for (index, row) in rows.enumerated() {
                guard row.depth > 0 else { continue }

                let rowOriginY = baseY + Float(index) * rowStride
                let rowTop = rowOriginY.rounded(.down)
                let rowBottom = max(rowTop + 1, (rowOriginY + rowHeight).rounded(.up))
                let strokeY = (rowOriginY + centerYLead).rounded(.down)

                for level in 0..<row.depth {
                    let cellX = baseX + Float(level) * indentation
                    let strokeX = (cellX + centerLead).rounded(.down)
                    if level == row.depth - 1 {
                        let continuesDownward = row.hasNextSibling
                        let verticalBottom = continuesDownward
                            ? rowBottom + continuationExtension
                            : strokeY + 1
                        list.addRect(UIRect(x: strokeX,
                                            y: rowTop,
                                            width: 1,
                                            height: max(1, verticalBottom - rowTop)),
                                  color: branchColor)
                        continue
                    }

                    let shouldDrawVertical = level < row.ancestorHasNextSiblings.count
                        && row.ancestorHasNextSiblings[level]
                    if shouldDrawVertical {
                        let verticalBottom = rowBottom + continuationExtension
                        list.addRect(UIRect(x: strokeX,
                                            y: rowTop,
                                            width: 1,
                                            height: max(1, verticalBottom - rowTop)),
                                     color: ancestorColor)
                    }
                }
            }
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column
        layout.alignItems = .stretch
        return layout
    }

    var _children: [any View] {
        [content]
    }
}

