import Foundation
import GuavaUIRuntime

/// Paints one paragraph — code chips, glyphs, link underlines and strike
/// lines — and resolves pointer input against the same flow.
struct RichTextSurface: _PrimitiveView {
    let source: RichTextStyleSource
    let onOpenLink: ((String) -> Void)?

    private struct PaintIdentity: Equatable {
        let paragraph: RichParagraph
        let palette: RichTextPalette
    }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        return node
    }

    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    /// The flow layout sizes the paragraph; the surface fills what it was given.
    func _updateLayout(_ layout: LayoutNode) {
        layout.setWidthPercent(100)
        layout.setHeightPercent(100)
    }

    func _updateNode(_ node: Node) {
        source.node = node
        let text = source.plainText, role = source.role
        node.accessibility = AccessibilitySemantics(role.accessibilityRole) {
            $0.label = text
            if case .heading(let level) = role { $0.value = "level \(level)" }
        }
        let source = source
        node.updateDraw(identity: PaintIdentity(paragraph: source.paragraph, palette: source.palette)) { [weak node] list, origin in
            guard let node, let env = TextEnvironmentHolder.current else { return }
            let paragraph = source.paragraph, palette = source.palette
            let flow = RichTextFlow.layout(paragraph, maxWidth: Float(node.frame.width), env: env)
            RichTextPainter(flow: flow, paragraph: paragraph, palette: palette,
                            hoveredLink: node.attachments[Self.hoveredLinkKey] as? Int,
                            focusedLink: FocusChainHolder.current?.isFocusVisible == true
                                ? node.attachments[Self.focusedLinkKey] as? Int : nil,
                            opacity: node.opacity)
                .paint(into: list, x: Float(origin.x), y: Float(origin.y), env: env)
        }
        installPointer(on: node)
    }

    private func installPointer(on node: Node) {
        guard let registry = InteractionRegistryHolder.current else { return }
        let destinations = source.destinations, open = onOpenLink, source = source
        let linkAt = { [weak node] (x: Float, y: Float) -> Int? in
            guard let node, open != nil, let env = TextEnvironmentHolder.current else { return nil }
            let frame = node.absoluteFrame
            let paragraph = source.paragraph
            let flow = RichTextFlow.layout(paragraph, maxWidth: Float(frame.width), env: env)
            guard let fragment = flow.fragment(at: x - Float(frame.minX), y - Float(frame.minY)) else { return nil }
            return paragraph.spans[fragment.span].link
        }
        let setHovered = { [weak node] (link: Int?) in
            guard let node, node.attachments[Self.hoveredLinkKey] as? Int != link else { return }
            node.attachments[Self.hoveredLinkKey] = link
            node.cursor = link == nil ? nil : .pointer
            node.markRenderDirty(reason: .styleSet(field: Self.hoveredLinkKey))
        }
        registry.setHover(node) { phase in if phase == .leave { setHovered(nil) } }
        registry.setMotion(node) { event, phase in
            guard phase != .capture else { return .ignored }
            setHovered(linkAt(event.x, event.y))
            return .ignored
        }
        registry.setPointer(node) { [weak node] event, phase, eventPhase in
            guard let node, eventPhase != .capture, event.button == .left else { return .ignored }
            switch phase {
            case .down:
                guard let link = linkAt(event.x, event.y) else { return .ignored }
                node.attachments[Self.pressedLinkKey] = link
                PointerCaptureHolder.current?.acquire(node, allowsGestureTransfer: true)
                return .handled
            case .up:
                guard let pressed = node.attachments.removeValue(forKey: Self.pressedLinkKey) as? Int else { return .ignored }
                if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
                if linkAt(event.x, event.y) == pressed, pressed < destinations.count { open?(destinations[pressed]) }
                return .handled
            }
        }
    }

    static let hoveredLinkKey = "__rich_text_hovered_link"
    static let pressedLinkKey = "__rich_text_pressed_link"
    static let focusedLinkKey = "__rich_text_focused_link"
}

private extension RichTextRole {
    var accessibilityRole: AccessibilityRole {
        switch self {
        case .heading: .heading
        case .paragraph, .codeBlock: .staticText
        }
    }
}

struct RichTextPainter {
    let flow: RichTextFlow
    let paragraph: RichParagraph
    let palette: RichTextPalette
    let hoveredLink: Int?
    let focusedLink: Int?
    let opacity: Float

    func paint(into list: DrawList, x: Float, y: Float, env: TextEnvironment) {
        for fragment in flow.fragments where paragraph.spans[fragment.span].traits.contains(.code) {
            let line = flow.lines[fragment.line]
            let inset: Float = 2
            let rect = UIRect(x: x + fragment.minX, y: y + line.baseline - fragment.ascent - inset,
                              width: fragment.maxX - fragment.minX,
                              height: fragment.ascent + fragment.descent + inset * 2)
            list.addRoundedRect(rect, radius: 4, color: palette.codeBackground.multipliedAlpha(opacity))
        }
        list.addText(flow.glyphs, origin: (x, y), color: palette.text.multipliedAlpha(opacity),
                     textureID: env.atlasTextureID, atlas: env.atlas) { glyph in
            flow.span(atOffset: Int(glyph.cluster)).map { color(for: paragraph.spans[$0]) }
        }
        for fragment in flow.fragments {
            let span = paragraph.spans[fragment.span]
            let line = flow.lines[fragment.line]
            let width = fragment.maxX - fragment.minX
            if span.link != nil {
                let offset = max(1, (fragment.descent * 0.4).rounded())
                list.addRect(UIRect(x: x + fragment.minX, y: y + line.baseline + offset, width: width, height: 1),
                             color: color(for: span))
            }
            if span.traits.contains(.strikethrough) {
                let middle = (fragment.ascent * 0.32).rounded()
                list.addRect(UIRect(x: x + fragment.minX, y: y + line.baseline - middle, width: width, height: 1),
                             color: color(for: span))
            }
            // Keyboard focus rings every wrapped fragment of the link.
            if let focusedLink, span.link == focusedLink {
                let rect = UIRect(x: x + fragment.minX - 4, y: y + line.top - 1, width: width + 8, height: line.height + 2)
                list.addRoundedRectStroke(rect, radius: 4, width: 2, color: palette.focusRing.multipliedAlpha(opacity))
            }
        }
    }

    private func color(for span: RichParagraph.Span) -> Color {
        let base: Color = if let link = span.link {
            link == hoveredLink ? palette.linkHover : palette.link
        } else {
            palette.text
        }
        return base.multipliedAlpha(opacity)
    }
}
