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
        let scope = node.compositionValue(of: TextSelectionScope.key)
        // Selectable paragraphs take focus on click for copy shortcuts, but are
        // not Tab stops: links are the keyboard targets inside text.
        node.isFocusable = scope != nil
        node.isTabStop = false
        scope?.register(node, text: { source.plainText }, offsetAt: { [weak node] point in
            guard let node, let env = TextEnvironmentHolder.current else { return 0 }
            let frame = node.absoluteFrame
            return RichTextFlow.layout(source.paragraph, maxWidth: Float(frame.width), env: env)
                .offset(at: Float(point.x - frame.minX), Float(point.y - frame.minY))
        })
        node.updateDraw(identity: PaintIdentity(paragraph: source.paragraph, palette: source.palette)) { [weak node] list, origin in
            guard let node, let env = TextEnvironmentHolder.current else { return }
            let paragraph = source.paragraph, palette = source.palette
            let flow = RichTextFlow.layout(paragraph, maxWidth: Float(node.frame.width), env: env)
            RichTextPainter(flow: flow, paragraph: paragraph, palette: palette,
                            hoveredLink: node.attachments[Self.hoveredLinkKey] as? Int,
                            focusedLink: FocusChainHolder.current?.isFocusVisible == true
                                ? node.attachments[Self.focusedLinkKey] as? Int : nil,
                            selection: scope?.range(for: node),
                            opacity: node.opacity)
                .paint(into: list, x: Float(origin.x), y: Float(origin.y), env: env)
        }
        installPointer(on: node, scope: scope)
    }

    private func installPointer(on node: Node, scope: TextSelectionScope?) {
        guard let registry = InteractionRegistryHolder.current else { return }
        let destinations = source.destinations, open = onOpenLink, source = source
        let flowFor = { (node: Node) -> RichTextFlow? in
            guard let env = TextEnvironmentHolder.current else { return nil }
            return RichTextFlow.layout(source.paragraph, maxWidth: Float(node.absoluteFrame.width), env: env)
        }
        let linkAt = { [weak node] (x: Float, y: Float) -> Int? in
            guard let node, open != nil, let flow = flowFor(node) else { return nil }
            let frame = node.absoluteFrame
            guard let fragment = flow.fragment(at: x - Float(frame.minX), y - Float(frame.minY)) else { return nil }
            return source.paragraph.spans[fragment.span].link
        }
        let setHovered = { [weak node] (link: Int?) in
            guard let node else { return }
            node.cursor = link != nil ? .pointer : scope != nil && node.supportsControlHover ? .ibeam : nil
            guard node.attachments[Self.hoveredLinkKey] as? Int != link else { return }
            node.attachments[Self.hoveredLinkKey] = link
            node.markRenderDirty(reason: .styleSet(field: Self.hoveredLinkKey))
        }
        let point = { (x: Float, y: Float) in CGPoint(x: CGFloat(x), y: CGFloat(y)) }
        registry.setHover(node) { phase in if phase == .leave { setHovered(nil) } }
        registry.setMotion(node) { [weak node] event, phase in
            guard phase != .capture else { return .ignored }
            setHovered(linkAt(event.x, event.y))
            guard let node, node.attachments[Self.selectingKey] as? Bool == true, let scope,
                  let position = scope.position(at: point(event.x, event.y)) else { return .ignored }
            scope.extend(to: position)
            return .handled
        }
        registry.setPointer(node) { [weak node] event, phase, eventPhase in
            guard let node, eventPhase != .capture, event.button == .left else { return .ignored }
            switch phase {
            case .down:
                if let link = linkAt(event.x, event.y) {
                    node.attachments[Self.pressedLinkKey] = link
                    PointerCaptureHolder.current?.acquire(node, allowsGestureTransfer: true)
                    return .handled
                }
                guard let scope else { return .ignored }
                guard node.supportsControlHover else {
                    // Touch keeps drags for scrolling; a long press selects instead.
                    node.attachments[Self.touchPressKey] = (Date(), point(event.x, event.y))
                    return .ignored
                }
                let here = point(event.x, event.y)
                if event.clicks >= 3 { scope.selectParagraph(node) }
                else if event.clicks == 2 { scope.selectWord(at: here) }
                else if let position = scope.position(at: here) {
                    if event.modifiers.isDisjoint(with: .shift) { scope.select(from: position, to: position) }
                    else { scope.extend(to: position) }
                }
                node.attachments[Self.selectingKey] = event.clicks < 2
                PointerCaptureHolder.current?.acquire(node)
                // Focus without a ring, so copy and select-all shortcuts reach the paragraph.
                FocusChainHolder.current?.focus(node, visible: false)
                return .handled
            case .up:
                if let (start, origin) = node.attachments.removeValue(forKey: Self.touchPressKey) as? (Date, CGPoint) {
                    let here = point(event.x, event.y)
                    guard let scope, Date().timeIntervalSince(start) >= 0.45,
                          hypot(here.x - origin.x, here.y - origin.y) < 10 else { return .ignored }
                    scope.selectWord(at: here)
                    scope.requestMenu?(here)
                    return .handled
                }
                if node.attachments.removeValue(forKey: Self.selectingKey) != nil {
                    if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
                    return .handled
                }
                guard let pressed = node.attachments.removeValue(forKey: Self.pressedLinkKey) as? Int else { return .ignored }
                if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
                if linkAt(event.x, event.y) == pressed, pressed < destinations.count { open?(destinations[pressed]) }
                return .handled
            }
        }
        guard let scope else { registry.setKey(node) { _, _ in .ignored }; return }
        registry.setKey(node) { event, phase in
            guard phase != .capture else { return .ignored }
            let primary = !event.modifiers.isDisjoint(with: .gui) || !event.modifiers.isDisjoint(with: .ctrl)
            switch event.scancode {
            case Scancode.c where primary:
                guard scope.hasSelection else { return .ignored }
                scope.copy()
                return .handled
            case Scancode.a where primary:
                scope.selectAll()
                return .handled
            case Scancode.escape:
                guard scope.hasSelection else { return .ignored }
                scope.clear()
                return .handled
            default:
                return .ignored
            }
        }
    }

    static let hoveredLinkKey = "__rich_text_hovered_link"
    static let pressedLinkKey = "__rich_text_pressed_link"
    static let focusedLinkKey = "__rich_text_focused_link"
    static let selectingKey = "__rich_text_selecting"
    static let touchPressKey = "__rich_text_touch_press"
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
    var selection: Range<Int>? = nil
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
        if let selection {
            for (sx, sy, sw, sh) in flow.selectionRects(selection) {
                list.addRect(UIRect(x: x + sx, y: y + sy, width: sw, height: sh), color: palette.selection.multipliedAlpha(opacity))
            }
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
