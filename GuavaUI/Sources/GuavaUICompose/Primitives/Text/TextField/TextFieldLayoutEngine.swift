#if canImport(CoreGraphics)
import CoreGraphics
#endif
import EngineKernel
import GuavaUIRuntime

extension TextField {
    struct LayoutEngine {
        struct RenderState {
            let buffer: TextBuffer
            let cursorIndex: Int
            let compositionRange: Range<Int>?
            let showsPlaceholder: Bool
            let isComposing: Bool
        }
        struct RenderCacheKey: Equatable {
            let root: ObjectIdentifier
            let version: UInt64
            let visibleRows: Range<Int>
            let totalRows: Int
            let font: Font
            let lineHeight: Float
            let letterSpacing: Float
            let atlasID: ObjectIdentifier
            let availableTextWidth: Float
            let secure: Bool
        }
        final class RenderCacheEntry {
            let key: RenderCacheKey
            let layout: TextLayoutResult
            let document: TextDocumentLayout
            init(key: RenderCacheKey, layout: TextLayoutResult, document: TextDocumentLayout) {
                self.key = key; self.layout = layout; self.document = document
            }
        }
        struct CaretLocation { let x: Float; let topY: Float }
        struct ViewportMetrics { let textOriginX: Float; let textOriginY: Float; let availableTextWidth: Float; let rawCaret: CaretLocation }
        struct ScrollbarMetrics { let trackRect: UIRect; let thumbRect: UIRect }
        private static let renderCacheAttachmentKey = "__textfield_render_cache"
        private static let documentAttachmentKey = "__textfield_document_layout"
        let textField: TextField
        var letterSpacing: Float = 0

        func makeRenderState(current: TextBuffer, state: FieldState, isFocused: Bool) -> RenderState {
            guard isFocused, state.composition.isActive else {
                if current.isEmpty {
                    if state.renderDraft.placeholder != textField.placeholder {
                        state.renderDraft.placeholder = textField.placeholder
                        state.renderDraft.placeholderBuffer = TextBuffer(textField.placeholder)
                    }
                    return RenderState(buffer: state.renderDraft.placeholderBuffer, cursorIndex: 0,
                                       compositionRange: nil, showsPlaceholder: true, isComposing: false)
                }
                return RenderState(buffer: current, cursorIndex: clamp(state.selection.cursorIndex, 0, current.characterCount),
                                   compositionRange: nil, showsPlaceholder: false, isComposing: false)
            }
            let cursor = clamp(state.selection.cursorIndex, 0, current.characterCount)
            let range = textField.selectionRange(state) ?? cursor..<cursor
            let preview: TextBuffer
            if let cached = state.renderDraft.preview, cached.source == current, cached.range == range, cached.text == state.composition.text {
                preview = cached.buffer
            } else {
                preview = current.replace(characterRange: range, with: state.composition.text)
                state.renderDraft.preview = CompositionPreview(source: current, range: range, text: state.composition.text, buffer: preview)
            }
            let startByte = current.utf8Offset(forCharacterIndex: range.lowerBound)
            let endByte = startByte + state.composition.text.utf8.count
            let offset = state.composition.length > 0 ? state.composition.start + state.composition.length : state.composition.text.count
            let caretByte = startByte + state.composition.text.prefix(clamp(offset, 0, state.composition.text.count)).utf8.count
            var first = preview.characterIndex(forUTF8Offset: startByte)
            if preview.utf8Offset(forCharacterIndex: first) > startByte { first = max(0, first - 1) }
            return RenderState(buffer: preview, cursorIndex: preview.characterIndex(forUTF8Offset: caretByte),
                               compositionRange: first..<preview.characterIndex(forUTF8Offset: endByte), showsPlaceholder: false, isComposing: true)
        }

        func document(in buffer: TextBuffer, node: Node, env: TextEnvironment, font: Font,
                      lineHeight: Float, availableTextWidth: Float, placeholder: Bool = false) -> TextDocumentLayout {
            let width = textField.layout.axis == .vertical && textField.layout.wrapsLines ? max(1, availableTextWidth) : .infinity
            let geometry = TextLineGeometry(font: font, lineHeight: lineHeight, letterSpacing: letterSpacing,
                                            atlas: ObjectIdentifier(env.atlas), width: width, secure: textField.behavior.secure && !placeholder)
            if let cached = node.attachments[Self.documentAttachmentKey] as? TextDocumentLayout {
                cached.update(buffer: buffer, geometry: geometry); return cached
            }
            let result = TextDocumentLayout(buffer: buffer, geometry: geometry)
            node.attachments[Self.documentAttachmentKey] = result; return result
        }
        func cachedRenderLayout(node: Node, state: FieldState, env: TextEnvironment, renderState: RenderState,
                                font: Font, lineHeight: Float, availableTextWidth: Float) -> RenderCacheEntry {
            let document = document(in: renderState.buffer, node: node, env: env, font: font, lineHeight: lineHeight,
                                    availableTextWidth: availableTextWidth, placeholder: renderState.showsPlaceholder)
            state.scroll.visibleHeight = max(lineHeight, Float(node.frame.height) - TextField.verticalInset(for: lineHeight) * 2)
            var revealCaretX: Float?
            if state.scroll.horizontal.viewportWidth != availableTextWidth, FocusChainHolder.current?.focused === node {
                revealCaretX = document.caret(atCharacter: renderState.cursorIndex,
                    lineEndAffinity: !renderState.isComposing && state.selection.lineEndAffinity, environment: env).x
            }
            if state.scroll.needsCaretReveal {
                let caret = document.caret(atCharacter: renderState.cursorIndex,
                    lineEndAffinity: !renderState.isComposing && state.selection.lineEndAffinity, environment: env)
                revealCaretX = caret.x
                let top = Float(caret.row) * lineHeight, bottom = top + lineHeight
                if bottom > state.scroll.offsetY + state.scroll.visibleHeight { state.scroll.offsetY = max(0, bottom - state.scroll.visibleHeight) }
                else if top < state.scroll.offsetY { state.scroll.offsetY = top }
                state.scroll.needsCaretReveal = false
            }
            updateScroll(state, document: document, lineHeight: lineHeight)
            let first = max(0, Int(floor(state.scroll.offsetY / max(1, lineHeight))) - 1)
            let count = Int(ceil(state.scroll.visibleHeight / max(1, lineHeight))) + 3
            func key() -> RenderCacheKey {
                RenderCacheKey(root: renderState.buffer.identity, version: renderState.buffer.version, visibleRows: first..<(first + count),
                               totalRows: document.index.rowCount, font: font, lineHeight: lineHeight, letterSpacing: letterSpacing,
                               atlasID: ObjectIdentifier(env.atlas), availableTextWidth: availableTextWidth, secure: document.geometry.secure)
            }
            func updateHorizontal(_ width: Float) {
                if textField.layout.axis == .horizontal || !textField.layout.wrapsLines {
                    state.scroll.horizontal.synchronize(buffer: renderState.buffer, geometry: document.geometry,
                        viewportWidth: availableTextWidth, measuredWidth: width, revealCaret: revealCaretX)
                } else { state.scroll.horizontal = HorizontalScrollState() }
            }
            if let cached = node.attachments[Self.renderCacheAttachmentKey] as? RenderCacheEntry, cached.key == key() {
                updateHorizontal(cached.layout.totalWidth); return cached
            }
            let layout = document.visibleLayout(firstRow: first, rowCount: count, environment: env)
            updateHorizontal(layout.totalWidth)
            updateScroll(state, document: document, lineHeight: lineHeight)
            let result = RenderCacheEntry(key: key(), layout: layout, document: document)
            node.attachments[Self.renderCacheAttachmentKey] = result; return result
        }
        private func updateScroll(_ state: FieldState, document: TextDocumentLayout, lineHeight: Float) {
            state.scroll.contentHeight = Float(document.index.rowCount) * lineHeight
            state.scroll.maxY = max(0, state.scroll.contentHeight - state.scroll.visibleHeight)
            state.scroll.offsetY = clamp(state.scroll.offsetY, 0, state.scroll.maxY)
        }
        func updateViewport(node: Node, state: FieldState, origin: CGPoint, env: TextEnvironment,
                            renderState: RenderState, renderCache: RenderCacheEntry, font: Font, lineHeight: Float,
                            addonLeading: Float, addonTrailing: Float) -> ViewportMetrics {
            let inset = textField.horizontalInset(theme: node.theme)
            let caret = renderCache.document.caret(atCharacter: renderState.cursorIndex,
                lineEndAffinity: !renderState.isComposing && state.selection.lineEndAffinity, environment: env)
            updateScroll(state, document: renderCache.document, lineHeight: lineHeight)
            state.scroll.horizontal.leadingInset = inset + addonLeading
            node.contentOffset = CGPoint(x: CGFloat(state.scroll.horizontal.offset), y: CGFloat(state.scroll.offsetY))
            return ViewportMetrics(textOriginX: Float(origin.x) + inset + addonLeading - state.scroll.horizontal.offset,
                                   textOriginY: Float(origin.y) + textField.textOriginYOffset(frameHeight: Float(node.frame.height), lineHeight: lineHeight) - state.scroll.offsetY,
                                   availableTextWidth: renderCache.key.availableTextWidth,
                                   rawCaret: CaretLocation(x: caret.x, topY: Float(caret.row) * lineHeight))
        }
        func visibleLayout(from layout: TextLayoutResult, scrollOffsetY: Float, visibleHeight: Float, lineHeight: Float) -> TextLayoutResult {
            let lines = layout.lines.filter { $0.baselineY + lineHeight >= scrollOffsetY - lineHeight && $0.baselineY - lineHeight <= scrollOffsetY + visibleHeight + lineHeight }
            return TextLayoutResult(lines: lines, totalWidth: layout.totalWidth, totalHeight: layout.totalHeight)
        }
        func interactiveDocument(in buffer: TextBuffer, node: Node, env: TextEnvironment) -> TextDocumentLayout {
            let font = textField.resolvedFont(node: node, env: env), lineHeight = textField.resolvedLineHeight(node: node, env: env)
            let width = Float(node.frame.width) - textField.horizontalInset(theme: node.theme) * 2
                - textField.leadingAddonWidth(env: env, font: font, lineHeight: lineHeight, theme: node.theme)
                - textField.trailingAddonWidth(env: env, font: font, lineHeight: lineHeight, theme: node.theme)
                - textField.trailingControlWidth(isFocused: FocusChainHolder.current?.focused === node,
                    env: env, font: font, lineHeight: lineHeight, theme: node.theme)
            return document(in: buffer, node: node, env: env, font: font, lineHeight: lineHeight, availableTextWidth: width)
        }
        func characterIndex(atWindowPoint point: CGPoint, state: FieldState, node: Node) -> Int {
            guard let env = TextEnvironmentHolder.current else { return 0 }
            let font = textField.resolvedFont(node: node, env: env), lineHeight = textField.resolvedLineHeight(node: node, env: env)
            let leading = textField.horizontalInset(theme: node.theme) + textField.leadingAddonWidth(env: env, font: font, lineHeight: lineHeight, theme: node.theme)
            let x = Float(point.x - state.pointer.lastDrawOrigin.x) - leading + state.scroll.horizontal.offset
            let y = Float(point.y - state.pointer.lastDrawOrigin.y) - textField.textOriginYOffset(frameHeight: Float(node.frame.height), lineHeight: lineHeight) + state.scroll.offsetY
            let document = interactiveDocument(in: textField.text.wrappedValue, node: node, env: env)
            return document.character(atRow: Int(floor(max(0, y) / max(1, lineHeight))), x: x, environment: env)
        }
        func drawSelection(_ range: Range<Int>, in buffer: TextBuffer, env: TextEnvironment, font: Font, lineHeight: Float,
                           layout: TextLayoutResult, textOriginX: Float, textOriginY: Float, visibleTopY: Float,
                           visibleBottomY: Float, list: DrawList, color: Color) {
            drawRange(range, buffer: buffer, layout: layout, textOriginX: textOriginX, textOriginY: textOriginY,
                      lineHeight: lineHeight, visibleTopY: visibleTopY, visibleBottomY: visibleBottomY, underline: false, list: list, color: color)
        }
        func drawUnderline(_ range: Range<Int>, in buffer: TextBuffer, env: TextEnvironment, font: Font, lineHeight: Float,
                           layout: TextLayoutResult, textOriginX: Float, textOriginY: Float, visibleTopY: Float,
                           visibleBottomY: Float, list: DrawList, color: Color) {
            drawRange(range, buffer: buffer, layout: layout, textOriginX: textOriginX, textOriginY: textOriginY,
                      lineHeight: lineHeight, visibleTopY: visibleTopY, visibleBottomY: visibleBottomY, underline: true, list: list, color: color)
        }
        private func drawRange(_ range: Range<Int>, buffer: TextBuffer, layout: TextLayoutResult, textOriginX: Float,
                               textOriginY: Float, lineHeight: Float, visibleTopY: Float, visibleBottomY: Float,
                               underline: Bool, list: DrawList, color: Color) {
            let lower = buffer.utf8Offset(forCharacterIndex: range.lowerBound), upper = buffer.utf8Offset(forCharacterIndex: range.upperBound)
            for line in layout.lines {
                let top = line.topY
                guard top + lineHeight >= visibleTopY, top <= visibleBottomY,
                      lower <= Int(line.endCluster), upper > Int(line.startCluster) else { continue }
                func x(atByte byte: Int) -> Float {
                    if byte <= Int(line.startCluster) { return 0 }
                    if byte >= Int(line.endCluster) { return line.width }
                    return line.glyphs.first(where: { Int($0.cluster) >= byte })?.x ?? line.width
                }
                let xLo = x(atByte: max(lower, Int(line.startCluster))), xHi = x(atByte: min(upper, Int(line.endCluster)))
                list.addRect(UIRect(x: textOriginX + xLo, y: textOriginY + top + (underline ? lineHeight - 1 : 0),
                                   width: max(1, xHi - xLo), height: underline ? 1 : lineHeight), color: color)
            }
        }
        func scrollbarMetrics(state: FieldState, node: Node, origin: CGPoint) -> ScrollbarMetrics? {
            guard state.scroll.maxY > 0, state.scroll.contentHeight > state.scroll.visibleHeight else { return nil }
            let thickness = TextField.scrollbarTrackThickness, inset = TextField.scrollbarInset
            let x = Float(origin.x) + Float(node.frame.width) - thickness - inset, y = Float(origin.y) + inset
            let height = max(thickness * 2, Float(node.frame.height) - inset * 2)
            let thumbHeight = max(thickness * 2, height * state.scroll.visibleHeight / max(1, state.scroll.contentHeight))
            let progress = state.scroll.offsetY / state.scroll.maxY
            return ScrollbarMetrics(trackRect: UIRect(x: x, y: y, width: thickness, height: height),
                                    thumbRect: UIRect(x: x, y: y + (height - thumbHeight) * progress, width: thickness, height: thumbHeight))
        }
        func horizontalScrollbarMetrics(state: FieldState, node: Node, origin: CGPoint) -> ScrollbarMetrics? {
            let scroll = state.scroll.horizontal
            guard scroll.maximum > 0, scroll.viewportWidth > 0 else { return nil }
            let thickness = TextField.scrollbarTrackThickness, inset = TextField.scrollbarInset
            let width = max(thickness * 2, scroll.viewportWidth - inset * 2)
            let thumb = max(thickness * 2, width * scroll.viewportWidth / scroll.contentWidth)
            let x = Float(origin.x) + scroll.leadingInset + inset
            let y = Float(origin.y) + Float(node.frame.height) - thickness - inset
            return ScrollbarMetrics(trackRect: UIRect(x: x, y: y, width: width, height: thickness),
                thumbRect: UIRect(x: x + (width - thumb) * scroll.offset / scroll.maximum, y: y, width: thumb, height: thickness))
        }
        func refreshScrollMetrics(node: Node, state: FieldState, renderCache: RenderCacheEntry, lineHeight: Float) {
            state.scroll.visibleHeight = max(lineHeight, Float(node.frame.height) - TextField.verticalInset(for: lineHeight) * 2)
            updateScroll(state, document: renderCache.document, lineHeight: lineHeight)
            node.contentOffset = CGPoint(x: CGFloat(state.scroll.horizontal.offset), y: CGFloat(state.scroll.offsetY))
        }
    }
}
