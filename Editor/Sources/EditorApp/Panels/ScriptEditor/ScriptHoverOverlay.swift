import EditorCore
import GuavaUICompose
import GuavaUIRuntime

/// Paints the Swift hover popup.
///
/// Drawn through ``TooltipStore`` rather than as a flex child so the popup never
/// participates in layout, never clips against the editor's bounds, and is
/// composited above every panel — the same path `Button` tooltips take. Its own
/// node contributes nothing to layout; it only owns the draw registration.
struct ScriptHoverOverlay: View {
    let presentation: ScriptEditorHoverPresentation

    var body: some View {
        _ScriptHoverOverlayNode(presentation: presentation)
    }
}

struct _ScriptHoverOverlayNode: _PrimitiveView {
    let presentation: ScriptEditorHoverPresentation

    private static let maximumPopupWidth: Float = 460
    private static let paddingX: Float = 10
    private static let paddingY: Float = 8
    private static let blockGap: Float = 6
    private static let caretOffset: Float = 18
    private static let viewportInset: Float = 6

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.isFocusable = false
        return node
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        installZeroSize(on: layout)
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        installZeroSize(on: layout)
    }

    func _updateNode(_ node: Node) {
        node.isHitTestable = false
        node.isFocusable = false

        guard let anchor = presentation.anchor else {
            TooltipStoreHolder.current.unregister(node)
            return
        }
        let blocks = presentation.textBlocks
        guard !blocks.isEmpty else {
            TooltipStoreHolder.current.unregister(node)
            return
        }
        let draw: (DrawList) -> Void = { [weak node] list in
            guard let node else { return }
            self.draw(popupAt: anchor, blocks: blocks, node: node, list: list)
        }
        TooltipStoreHolder.current.register(node, draw: draw)
    }

    private func installZeroSize(on layout: LayoutNode) {
        layout.positionType = .absolute
        layout.setPosition(0, edge: .left)
        layout.setPosition(0, edge: .top)
        layout.width = 0
        layout.height = 0
    }

    private func draw(popupAt anchor: ScriptEditorHoverAnchor,
                      blocks: [ScriptHoverTextBlock],
                      node: Node,
                      list: DrawList) {
        guard let env = TextEnvironmentHolder.current else { return }
        let theme = node.theme

        let maximumTextWidth = Self.maximumPopupWidth - Self.paddingX * 2
        var laidOut: [(layout: TextLayoutResult, lineHeight: Float, role: ScriptHoverTextRole)] = []
        for block in blocks {
            let token = block.role == .signature
                ? theme.typography.mono
                : theme.typography.caption
            let layout = env.cachedLayout(text: block.text,
                                          font: token.font,
                                          lineHeight: token.lineHeight,
                                          maxWidth: maximumTextWidth,
                                          alignment: .leading)
            laidOut.append((layout, token.lineHeight, block.role))
        }

        let textHeight = laidOut.reduce(Float(0)) { $0 + $1.layout.totalHeight }
            + (laidOut.count > 1 ? Self.blockGap : 0)
        let width = min(Self.maximumPopupWidth,
                        (laidOut.map(\.layout.totalWidth).max() ?? 0) + Self.paddingX * 2)
        let height = textHeight + Self.paddingY * 2

        let origin = Self.resolveOrigin(for: anchor,
                                        popupSize: (width: width, height: height),
                                        viewport: list.viewportBounds)

        Self.drawChrome(rect: UIRect(x: origin.x, y: origin.y, width: width, height: height),
                        theme: theme,
                        node: node,
                        list: list)

        var cursorY = origin.y + Self.paddingY
        for (index, block) in laidOut.enumerated() {
            if index > 0 { cursorY += Self.blockGap }
            let color = block.role == .signature
                ? theme.colors.onSurface
                : theme.colors.onSurfaceMuted
            list.addText(block.layout,
                         origin: (origin.x + Self.paddingX, cursorY),
                         color: color.multipliedAlpha(node.opacity),
                         textureID: env.atlasTextureID,
                         atlas: env.atlas)
            cursorY += block.layout.totalHeight
        }
    }

    /// Places the popup below the pointer, flipping above it when the viewport
    /// bottom would clip the text and pinning horizontally inside the viewport.
    private static func resolveOrigin(for anchor: ScriptEditorHoverAnchor,
                                      popupSize: (width: Float, height: Float),
                                      viewport: UIRect?) -> (x: Float, y: Float) {
        var x = anchor.windowX
        var y = anchor.windowY + caretOffset
        guard let viewport else { return (x, y) }

        let inset = viewportInset
        let minimumX = viewport.x + inset
        let maximumX = viewport.x + viewport.width - popupSize.width - inset
        if maximumX >= minimumX {
            x = min(max(x, minimumX), maximumX)
        } else {
            x = minimumX
        }

        let minimumY = viewport.y + inset
        let maximumY = viewport.y + viewport.height - popupSize.height - inset
        if y > maximumY {
            let above = anchor.windowY - popupSize.height - caretOffset
            y = above >= minimumY ? above : max(minimumY, maximumY)
        }
        return (x, y)
    }

    private static func drawChrome(rect: UIRect,
                                   theme: Theme,
                                   node: Node,
                                   list: DrawList) {
        let background = theme.colors.surfaceFloating
            .composited(over: Color.black.multipliedAlpha(0.22))
            .multipliedAlpha(node.opacity)
        list.addRoundedRect(rect, radius: max(4, theme.radius.sm), color: background)

        let border = theme.colors.border.multipliedAlpha(node.opacity)
        list.addRect(UIRect(x: rect.x, y: rect.y, width: rect.width, height: 1), color: border)
        list.addRect(UIRect(x: rect.x,
                            y: rect.y + rect.height - 1,
                            width: rect.width,
                            height: 1),
                     color: border)
        list.addRect(UIRect(x: rect.x, y: rect.y, width: 1, height: rect.height), color: border)
        list.addRect(UIRect(x: rect.x + rect.width - 1,
                            y: rect.y,
                            width: 1,
                            height: rect.height),
                     color: border)
    }
}
