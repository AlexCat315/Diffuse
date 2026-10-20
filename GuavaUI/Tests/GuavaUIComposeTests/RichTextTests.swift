import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("RichText flow", .serialized)
struct RichTextTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }

    private func withEnvironment(_ test: (TextEnvironment) -> Void) {
        GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            let env = TestTextEnvironmentFactory.make()
            TextEnvironmentHolder.current = env
            defer { TextEnvironmentHolder.current = previous }
            test(env)
        }
    }

    private func paragraph(_ spans: [(String, RichTextTraits, Int?)], wraps: Bool = true) -> RichParagraph {
        RichParagraph(spans: spans.map { text, traits, link in
            var font = Font.system(size: 16)
            if traits.contains(.code) { font = .monospaced(size: 15) }
            return .init(text: text, font: font, lineHeight: 20, traits: traits, link: link)
        }, wraps: wraps)
    }

    private func visibleText(_ flow: RichTextFlow, line: Int) -> String {
        let bytes = Array(flow.text.utf8)[flow.lines[line].startOffset..<flow.lines[line].endOffset]
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("Runs wrap together at spaces and every line fits the width")
    func wrapsAcrossRuns() {
        withEnvironment { env in
            let flow = RichTextFlow.layout(paragraph([
                ("The quick ", [], nil), ("brown", .bold, nil), (" fox jumps over the ", [], nil),
                ("lazy", .italic, nil), (" dog again and again", [], nil),
            ]), maxWidth: 120, env: env)
            #expect(flow.lines.count > 2)
            for line in flow.lines { #expect(line.width <= 120.5) }
            // Lines tile the text: no character is dropped or repeated.
            for (previous, next) in zip(flow.lines, flow.lines.dropFirst()) {
                #expect(previous.endOffset == next.startOffset)
            }
            let words = flow.lines.indices.map { visibleText(flow, line: $0) }.joined(separator: " ")
            #expect(words == "The quick brown fox jumps over the lazy dog again and again")
            #expect(flow.height == Float(flow.lines.count) * 20)
        }
    }

    @Test("Without a width limit a paragraph stays on one line")
    func intrinsicWidth() {
        withEnvironment { env in
            let flow = RichTextFlow.layout(paragraph([("one ", [], nil), ("two", .bold, nil)]), maxWidth: .infinity, env: env)
            #expect(flow.lines.count == 1)
            #expect(flow.width > 0)
        }
    }

    @Test("Ideographs break between characters but closing punctuation never starts a line")
    func ideographicBreaks() {
        let breaks = LineBreaks.opportunities(in: "中文，段落")
        let comma = "中文".utf8.count
        #expect(breaks.contains("中".utf8.count))
        #expect(!breaks.contains(comma))
        #expect(breaks.contains(comma + "，".utf8.count))
        // Hyphens and slashes inside long tokens are break points, plain words are not.
        let url = LineBreaks.opportunities(in: "a/b-c word")
        #expect(url.contains(2) && url.contains(4) && url.contains(6))
        #expect(!url.contains(1))
    }

    @Test("Hard breaks end lines and blank lines keep their height")
    func hardBreaks() {
        withEnvironment { env in
            let flow = RichTextFlow.layout(paragraph([("first\n\nthird", [], nil)]), maxWidth: 400, env: env)
            #expect(flow.lines.count == 3)
            #expect(visibleText(flow, line: 0) == "first")
            #expect(flow.lines[1].startOffset == flow.lines[1].endOffset)
            #expect(visibleText(flow, line: 2) == "third")
            #expect(flow.height == 60)
        }
    }

    @Test("Inline code is padded on both sides and its fragment carries the chip")
    func codePadding() {
        withEnvironment { env in
            let plain = RichTextFlow.layout(paragraph([("x ", [], nil), ("code", [], nil)]), maxWidth: .infinity, env: env)
            let code = RichTextFlow.layout(paragraph([("x ", [], nil), ("code", .code, nil)]), maxWidth: .infinity, env: env)
            let chip = code.fragments.first { $0.span == 1 }!
            #expect(chip.maxX - chip.minX > 0)
            let codeGlyph = code.glyphs.lines[0].glyphs.first { Int($0.cluster) == 2 }!
            #expect(codeGlyph.x > chip.minX)
            #expect(code.width > plain.width - 8)
        }
    }

    @Test("Points map to caret offsets and ranges map to highlight rectangles")
    func caretMapping() {
        withEnvironment { env in
            let flow = RichTextFlow.layout(paragraph([("alpha beta gamma delta", [], nil)]), maxWidth: 90, env: env)
            #expect(flow.offset(at: -10, 5) == 0)
            #expect(flow.offset(at: 2000, 2000) == flow.text.utf8.count)
            let second = flow.lines[1]
            #expect(flow.offset(at: 0, second.top + 1) == second.startOffset)
            let rects = flow.selectionRects(0..<flow.text.utf8.count)
            #expect(rects.count == flow.lines.count)
            #expect(flow.selectionRects(3..<3).isEmpty)
        }
    }

    @Test("A click on any fragment of a link opens it; hover shows the pointer cursor")
    func linkActivation() {
        withEnvironment { _ in
            let registry = InteractionRegistry(), capture = PointerCapture()
            let oldRegistry = InteractionRegistryHolder.current, oldCapture = PointerCaptureHolder.current
            InteractionRegistryHolder.current = registry
            PointerCaptureHolder.current = capture
            defer { InteractionRegistryHolder.current = oldRegistry; PointerCaptureHolder.current = oldCapture }
            var opened: [String] = []
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: RichText([
                RichTextRun("Read the "), RichTextRun("style guide", link: "guide://style"), RichTextRun(" today."),
            ]) { opened.append($0) })
            graph.computeLayout(width: 400, height: 200)
            let surface = nodes(graph.tree.root!).first { $0.accessibility?.role == .staticText }!
            let frame = surface.absoluteFrame
            let pointer = registry.handlers(for: surface).pointer!
            let motion = registry.handlers(for: surface).motion!
            let y = Float(frame.minY) + 8
            // Plain words are not links: a press there starts a selection instead.
            _ = pointer(MouseButtonEvent(button: .left, x: Float(frame.minX) + 4, y: y, clicks: 1), .down, .target)
            _ = pointer(MouseButtonEvent(button: .left, x: Float(frame.minX) + 4, y: y, clicks: 1), .up, .target)
            #expect(opened.isEmpty)
            // Find the link by sweeping the line, as a pointer would.
            let linkX = stride(from: Float(frame.minX), to: Float(frame.maxX), by: 2).first { x in
                _ = motion(MouseMotionEvent(x: x, y: y, deltaX: 0, deltaY: 0), .target)
                return surface.cursor == .pointer
            }
            #expect(linkX != nil)
            guard let linkX else { return }
            #expect(pointer(MouseButtonEvent(button: .left, x: linkX + 4, y: y, clicks: 1), .down, .target) == .handled)
            #expect(pointer(MouseButtonEvent(button: .left, x: linkX + 4, y: y, clicks: 1), .up, .target) == .handled)
            #expect(opened == ["guide://style"])
            // Releasing away from the link cancels it.
            _ = pointer(MouseButtonEvent(button: .left, x: linkX + 4, y: y, clicks: 1), .down, .target)
            _ = pointer(MouseButtonEvent(button: .left, x: Float(frame.minX) + 2, y: y, clicks: 1), .up, .target)
            #expect(opened.count == 1)
            registry.handlers(for: surface).hover?(.leave)
            #expect(surface.cursor == .ibeam)
            graph.install(root: EmptyView())
        }
    }

    @Test("Italic survives text scaling and family resolution")
    func italicFont() {
        let italic = Font.system(size: 14).italic()
        #expect(italic.isItalic)
        #expect(TextScaler(2).scale(italic).isItalic)
        #expect(italic.weight(.bold).isItalic && italic.weight(.bold).weight == .bold)
    }
}

@Suite("RichText styling", .serialized)
struct RichTextStylingTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }

    @Test("Font and foreground modifiers on the paragraph reach measurement and paint")
    func modifiersApply() {
        GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: Column {
                RichText([RichTextRun("Body")])
                RichText([RichTextRun("Large")]).font(.system(size: 40))
            })
            graph.computeLayout(width: 400, height: 400)
            let surfaces = nodes(graph.tree.root!).filter { $0.accessibility?.role == .staticText }
            #expect(surfaces.count == 2)
            #expect(surfaces[1].frame.height > surfaces[0].frame.height + 10)
            graph.install(root: EmptyView())
        }
    }
}

@Suite("RichText links", .serialized)
struct RichTextLinkTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }
    private func key(_ code: UInt32) -> KeyEvent { KeyEvent(scancode: code, keycode: 0, modifiers: [], isRepeat: false) }

    private func withScene(_ test: (ViewGraph, InteractionRegistry, FocusChain) -> Void) {
        GlobalTestLock.locked {
            let previousText = TextEnvironmentHolder.current, previousRegistry = InteractionRegistryHolder.current
            let previousFocus = FocusChainHolder.current
            let registry = InteractionRegistry(), focus = FocusChain()
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            InteractionRegistryHolder.current = registry
            FocusChainHolder.current = focus
            defer {
                TextEnvironmentHolder.current = previousText
                InteractionRegistryHolder.current = previousRegistry
                FocusChainHolder.current = previousFocus
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            test(graph, registry, focus)
            graph.install(root: EmptyView())
        }
    }

    @Test("Each link is a focusable link element over its first fragment that opens on Return")
    func anchors() {
        withScene { graph, registry, focus in
            var opened: [String] = []
            graph.install(root: RichText([
                RichTextRun("Read the "), RichTextRun("style ", link: "guide://style"),
                RichTextRun("guide", traits: .bold, link: "guide://style"),
                RichTextRun(" or the "), RichTextRun("faq", link: "guide://faq"), RichTextRun("."),
            ]) { opened.append($0) })
            graph.computeLayout(width: 400, height: 200)
            let links = nodes(graph.tree.root!).filter { $0.accessibility?.role == .link }
            #expect(links.map { $0.accessibility?.label } == ["style guide", "faq"])
            #expect(links.map { $0.accessibility?.help } == ["guide://style", "guide://faq"])
            #expect(links.allSatisfy { $0.isFocusable && !$0.isHitTestable })
            let paragraph = nodes(graph.tree.root!).first { $0.accessibility?.role == .staticText }!.absoluteFrame
            for link in links { #expect(paragraph.contains(link.absoluteFrame) && link.absoluteFrame.width > 10) }
            #expect(links[0].absoluteFrame.maxX <= links[1].absoluteFrame.minX)

            _ = registry.handlers(for: links[1]).key?(key(Scancode.return), .target)
            links[0].accessibilityActions.activate?()
            #expect(opened == ["guide://faq", "guide://style"])

            // Focus is remembered on the paragraph so every fragment can be ringed.
            focus.focus(links[1])
            let surface = nodes(graph.tree.root!).first { $0.accessibility?.role == .staticText }!
            #expect(surface.attachments[RichTextSurface.focusedLinkKey] as? Int == 1)
            focus.focus(nil)
            #expect(surface.attachments[RichTextSurface.focusedLinkKey] == nil)
        }
    }

    @Test("Without a link handler links are shown but not focusable")
    func inertLinks() {
        withScene { graph, registry, _ in
            graph.install(root: RichText([RichTextRun("see "), RichTextRun("docs", link: "guide://docs")]))
            graph.computeLayout(width: 400, height: 200)
            let link = nodes(graph.tree.root!).first { $0.accessibility?.role == .link }
            #expect(link?.isFocusable == false)
            #expect(link?.accessibility?.state.isEnabled == false)
            #expect(link.flatMap { registry.handlers(for: $0).key } == nil)
        }
    }
}
