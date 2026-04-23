import CoreGraphics
import EngineKernel
import GuavaUIRuntime

extension TextField {
    struct LayoutEngine {
        struct RenderState {
            let displayText: String
            let measurementText: String
            let cursorIndex: Int
            let compositionRange: Range<Int>?
            let showsPlaceholder: Bool
            let isComposing: Bool
        }

        struct RenderCacheKey: Equatable {
            let displayText: String
            let measurementText: String
            let font: Font
            let lineHeight: Float
            let atlasID: ObjectIdentifier
            let availableTextWidth: Float
        }

        final class RenderCacheEntry {
            let key: RenderCacheKey
            let layout: TextLayoutResult

            init(key: RenderCacheKey,
                 layout: TextLayoutResult) {
                self.key = key
                self.layout = layout
            }
        }

        struct CaretLocation {
            let x: Float
            let topY: Float
        }

        struct ViewportMetrics {
            let textOriginX: Float
            let textOriginY: Float
            let availableTextWidth: Float
            let rawCaret: CaretLocation
        }

        struct ScrollbarMetrics {
            let trackRect: UIRect
            let thumbRect: UIRect
        }

        private static let renderCacheAttachmentKey = "__textfield_render_cache"

        let textField: TextField

        func makeRenderState(current: String,
                             state: FieldState,
                             isFocused: Bool) -> RenderState {
            guard isFocused, state.isComposing else {
                if current.isEmpty {
                    return RenderState(
                        displayText: textField.placeholder,
                        measurementText: "",
                        cursorIndex: 0,
                        compositionRange: nil,
                        showsPlaceholder: true,
                        isComposing: false
                    )
                }
                return RenderState(
                    displayText: current,
                    measurementText: current,
                    cursorIndex: clamp(state.cursorIndex, 0, current.count),
                    compositionRange: nil,
                    showsPlaceholder: false,
                    isComposing: false
                )
            }

            let replaceRange = textField.selectionRange(state) ?? (state.cursorIndex..<state.cursorIndex)
            var preview = current
            let lower = preview.index(preview.startIndex, offsetBy: replaceRange.lowerBound)
            let upper = preview.index(preview.startIndex, offsetBy: replaceRange.upperBound)
            preview.replaceSubrange(lower..<upper, with: state.compositionText)

            let compositionStart = replaceRange.lowerBound
            let compositionEnd = compositionStart + state.compositionText.count
            let cursorOffset = state.compositionLength > 0
                ? state.compositionStart + state.compositionLength
                : state.compositionText.count

            return RenderState(
                displayText: preview,
                measurementText: preview,
                cursorIndex: compositionStart + clamp(cursorOffset, 0, state.compositionText.count),
                compositionRange: compositionStart..<compositionEnd,
                showsPlaceholder: false,
                isComposing: true
            )
        }

        func cachedRenderLayout(node: Node,
                                env: TextEnvironment,
                                displayText: String,
                                measurementText: String,
                                font: Font,
                                lineHeight: Float,
                                availableTextWidth: Float) -> RenderCacheEntry {
            let key = RenderCacheKey(displayText: displayText,
                                     measurementText: measurementText,
                                     font: font,
                                     lineHeight: lineHeight,
                                     atlasID: ObjectIdentifier(env.atlas),
                                     availableTextWidth: max(0, availableTextWidth))
            if let cached = node.attachments[Self.renderCacheAttachmentKey] as? RenderCacheEntry,
               cached.key == key {
                return cached
            }
            let layout = env.cachedLayout(
                text: displayText,
                font: font,
                lineHeight: lineHeight,
                maxWidth: layoutMaxWidth(for: displayText,
                                         availableTextWidth: availableTextWidth),
                alignment: .leading
            )
            let entry = RenderCacheEntry(key: key, layout: layout)
            node.attachments[Self.renderCacheAttachmentKey] = entry
            return entry
        }

        func updateViewport(node: Node,
                            state: FieldState,
                            origin: CGPoint,
                            env: TextEnvironment,
                            renderState: RenderState,
                            renderCache: RenderCacheEntry,
                            font: Font,
                            lineHeight: Float,
                            addonLeading: Float,
                            addonTrailing: Float) -> ViewportMetrics {
            let frameWidth = Float(node.frame.width)
            let insetX = textField.horizontalInset(theme: node.theme)
            let textOriginX = Float(origin.x) + insetX + addonLeading
                  let baseTextOriginY = Float(origin.y) + textField.textOriginYOffset(frameHeight: Float(node.frame.height),
                                                                                lineHeight: lineHeight)
                  refreshScrollMetrics(node: node,
                                   state: state,
                                   renderCache: renderCache,
                                   lineHeight: lineHeight)

            let rawCaret = caretLocation(in: renderState.measurementText,
                                         cursorIndex: clamp(renderState.cursorIndex, 0, renderState.measurementText.count),
                                         env: env,
                                         font: font,
                                         lineHeight: lineHeight,
                                         layout: renderCache.layout)
            let caretBottom = rawCaret.topY + lineHeight
            if caretBottom - state.scrollOffsetY > state.visibleTextHeight {
                state.scrollOffsetY = min(state.maxScrollY, caretBottom - state.visibleTextHeight)
            } else if rawCaret.topY < state.scrollOffsetY {
                state.scrollOffsetY = max(0, rawCaret.topY)
            }
            node.contentOffset = CGPoint(x: 0, y: CGFloat(state.scrollOffsetY))

            return ViewportMetrics(
                textOriginX: textOriginX,
                textOriginY: baseTextOriginY - state.scrollOffsetY,
                availableTextWidth: max(0, frameWidth - insetX * 2 - addonLeading - addonTrailing),
                rawCaret: rawCaret
            )
        }

        func visibleLayout(from layout: TextLayoutResult,
                           scrollOffsetY: Float,
                           visibleHeight: Float,
                           lineHeight: Float) -> TextLayoutResult {
            let visibleTop = scrollOffsetY - lineHeight
            let visibleBottom = scrollOffsetY + visibleHeight + lineHeight
            let lines = layout.lines.filter { line in
                let lineTop = line.baselineY - lineHeight
                let lineBottom = line.baselineY + lineHeight
                return lineBottom >= visibleTop && lineTop <= visibleBottom
            }
            return TextLayoutResult(lines: lines,
                                    totalWidth: layout.totalWidth,
                                    totalHeight: layout.totalHeight)
        }

        func characterIndex(atWindowPoint point: CGPoint,
                            state: FieldState,
                            node: Node) -> Int {
            guard let env = TextEnvironmentHolder.current else {
                return 0
            }
            let current = textField.text.wrappedValue

            let resolvedFont = textField.resolvedFont(node: node, env: env)
            let lineHeight = textField.resolvedLineHeight(node: node, env: env)
            let leadingInset = textField.horizontalInset(theme: node.theme)
                + textField.leadingAddonWidth(env: env,
                                              font: resolvedFont,
                                              lineHeight: lineHeight,
                                              theme: node.theme)
            let layout = interactiveLayout(in: current,
                                           node: node,
                                           env: env,
                                           font: resolvedFont,
                                           lineHeight: lineHeight)
            let ranges = lineRanges(in: current, layout: layout)
            guard !ranges.isEmpty else {
                return 0
            }
            let localX = Float(point.x) - Float(state.lastDrawOrigin.x) - leadingInset
            let localY = Float(point.y) - Float(state.lastDrawOrigin.y)
                - textField.textOriginYOffset(frameHeight: Float(node.frame.height), lineHeight: lineHeight)
                + state.scrollOffsetY

            let lineIndex = clamp(Int((max(localY, 0) / max(lineHeight, 1)).rounded(.down)),
                                  0,
                                  max(0, ranges.count - 1))
            let lineRange = ranges[lineIndex]
            let lineText = textField.substring(current, lineRange)
            if localX <= 0 {
                return lineRange.lowerBound
            }

            let glyphs = env.shape(text: lineText, font: resolvedFont)
            var pen: Float = 0
            for (index, glyph) in glyphs.enumerated() {
                let midpoint = pen + glyph.xAdvance * 0.5
                if localX < midpoint {
                    return lineRange.lowerBound + index
                }
                pen += glyph.xAdvance
            }
            return lineRange.upperBound
        }

        func characterIndex(inLineText text: String,
                            desiredX: Float,
                            env: TextEnvironment,
                            font: Font) -> Int {
            guard !text.isEmpty else { return 0 }
            guard desiredX > 0 else { return 0 }
            let glyphs = env.shape(text: text, font: font)
            var pen: Float = 0
            for (index, glyph) in glyphs.enumerated() {
                let midpoint = pen + glyph.xAdvance * 0.5
                if desiredX < midpoint {
                    return index
                }
                pen += glyph.xAdvance
            }
            return text.count
        }

        func lineRanges(in text: String, layout: TextLayoutResult? = nil) -> [Range<Int>] {
            guard let layout, !layout.lines.isEmpty else {
                return explicitLineRanges(in: text)
            }
            let boundaries = characterBoundaryUTF8Offsets(in: text)
            let mapped = layout.lines.map { line in
                let lower = characterIndex(forUTF8Offset: Int(line.startCluster), boundaries: boundaries)
                let upper = characterIndex(forUTF8Offset: Int(line.endCluster), boundaries: boundaries)
                return lower..<max(lower, upper)
            }
            return mapped.isEmpty ? [0..<0] : mapped
        }

        func explicitLineRanges(in text: String) -> [Range<Int>] {
            var ranges: [Range<Int>] = []
            var start = 0
            for (index, character) in text.enumerated() {
                if character == "\n" {
                    ranges.append(start..<index)
                    start = index + 1
                }
            }
            ranges.append(start..<text.count)
            return ranges.isEmpty ? [0..<0] : ranges
        }

        func lineIndex(for cursorIndex: Int, lineRanges: [Range<Int>]) -> Int {
            for (index, range) in lineRanges.enumerated() {
                if cursorIndex <= range.upperBound {
                    return index
                }
            }
            return max(0, lineRanges.count - 1)
        }

        func rangeLength(_ range: Range<Int>) -> Int {
            range.upperBound - range.lowerBound
        }

        func linePrefixWidth(in text: String,
                             upTo count: Int,
                             env: TextEnvironment,
                             font: Font,
                             lineHeight: Float) -> Float {
            let bounded = clamp(count, 0, text.count)
            guard bounded > 0 else { return 0 }
            let endIndex = text.index(text.startIndex, offsetBy: bounded)
            let prefix = String(text[text.startIndex..<endIndex])
            let layout = env.cachedLayout(
                text: prefix,
                font: font,
                lineHeight: lineHeight,
                maxWidth: .infinity,
                alignment: .leading
            )
            return layout.lines.last?.width ?? 0
        }

        func caretLocation(in text: String,
                           cursorIndex: Int,
                           env: TextEnvironment,
                           font: Font,
                           lineHeight: Float,
                           layout: TextLayoutResult? = nil) -> CaretLocation {
            let ranges = lineRanges(in: text, layout: layout)
            let line = lineIndex(for: clamp(cursorIndex, 0, text.count), lineRanges: ranges)
            let range = ranges[line]
            let column = clamp(cursorIndex - range.lowerBound, 0, rangeLength(range))
            let lineText = textField.substring(text, range)
            return CaretLocation(
                x: linePrefixWidth(in: lineText,
                                   upTo: column,
                                   env: env,
                                   font: font,
                                   lineHeight: lineHeight),
                topY: Float(line) * lineHeight
            )
        }

        func drawSelection(_ range: Range<Int>,
                           in text: String,
                           env: TextEnvironment,
                           font: Font,
                           lineHeight: Float,
                           layout: TextLayoutResult,
                           textOriginX: Float,
                           textOriginY: Float,
                           visibleTopY: Float,
                           visibleBottomY: Float,
                           list: DrawList,
                           color: Color) {
            let ranges = lineRanges(in: text, layout: layout)
            let startLine = lineIndex(for: range.lowerBound, lineRanges: ranges)
            let endLine = lineIndex(for: range.upperBound, lineRanges: ranges)
            for line in startLine...endLine {
                let lineTop = Float(line) * lineHeight
                let lineBottom = lineTop + lineHeight
                if lineBottom < visibleTopY || lineTop > visibleBottomY {
                    continue
                }
                let lineRange = ranges[line]
                let lower = max(range.lowerBound, lineRange.lowerBound)
                let upper = min(range.upperBound, lineRange.upperBound)
                guard upper > lower else { continue }
                let lineText = textField.substring(text, lineRange)
                let xLo = linePrefixWidth(in: lineText,
                                          upTo: lower - lineRange.lowerBound,
                                          env: env,
                                          font: font,
                                          lineHeight: lineHeight)
                let xHi = linePrefixWidth(in: lineText,
                                          upTo: upper - lineRange.lowerBound,
                                          env: env,
                                          font: font,
                                          lineHeight: lineHeight)
                list.addRect(
                    UIRect(x: textOriginX + xLo,
                           y: textOriginY + Float(line) * lineHeight,
                           width: max(1, xHi - xLo),
                           height: lineHeight),
                    color: color
                )
            }
        }

        func drawUnderline(_ range: Range<Int>,
                           in text: String,
                           env: TextEnvironment,
                           font: Font,
                           lineHeight: Float,
                           layout: TextLayoutResult,
                           textOriginX: Float,
                           textOriginY: Float,
                           visibleTopY: Float,
                           visibleBottomY: Float,
                           list: DrawList,
                           color: Color) {
            let ranges = lineRanges(in: text, layout: layout)
            let startLine = lineIndex(for: range.lowerBound, lineRanges: ranges)
            let endLine = lineIndex(for: range.upperBound, lineRanges: ranges)
            for line in startLine...endLine {
                let lineTop = Float(line) * lineHeight
                let lineBottom = lineTop + lineHeight
                if lineBottom < visibleTopY || lineTop > visibleBottomY {
                    continue
                }
                let lineRange = ranges[line]
                let lower = max(range.lowerBound, lineRange.lowerBound)
                let upper = min(range.upperBound, lineRange.upperBound)
                guard upper > lower else { continue }
                let lineText = textField.substring(text, lineRange)
                let xLo = linePrefixWidth(in: lineText,
                                          upTo: lower - lineRange.lowerBound,
                                          env: env,
                                          font: font,
                                          lineHeight: lineHeight)
                let xHi = linePrefixWidth(in: lineText,
                                          upTo: upper - lineRange.lowerBound,
                                          env: env,
                                          font: font,
                                          lineHeight: lineHeight)
                list.addRect(
                    UIRect(x: textOriginX + xLo,
                           y: textOriginY + Float(line) * lineHeight + lineHeight - 1,
                           width: max(1, xHi - xLo),
                           height: 1),
                    color: color
                )
            }
        }

        func scrollbarMetrics(state: FieldState,
                              node: Node,
                              origin: CGPoint) -> ScrollbarMetrics? {
            guard state.maxScrollY > 0, state.contentHeight > state.visibleTextHeight else { return nil }
            let trackThickness = TextField.scrollbarTrackThickness
            let inset = TextField.scrollbarInset
            let trackX = Float(origin.x) + Float(node.frame.width) - trackThickness - inset
            let trackY = Float(origin.y) + inset
            let trackH = max(trackThickness * 2, Float(node.frame.height) - inset * 2)
            let thumbH = max(trackThickness * 2,
                             trackH * (state.visibleTextHeight / max(state.contentHeight, 1)))
            let progress = state.maxScrollY > 0 ? state.scrollOffsetY / state.maxScrollY : 0
            let thumbY = trackY + (trackH - thumbH) * progress
            return ScrollbarMetrics(
                trackRect: UIRect(x: trackX,
                                  y: trackY,
                                  width: trackThickness,
                                  height: trackH),
                thumbRect: UIRect(x: trackX,
                                  y: thumbY,
                                  width: trackThickness,
                                  height: thumbH)
            )
        }

        func refreshScrollMetrics(node: Node,
                                  state: FieldState,
                                  renderCache: RenderCacheEntry,
                                  lineHeight: Float) {
            let frameHeight = Float(node.frame.height)
            let availableTextHeight = max(lineHeight,
                                          frameHeight - TextField.verticalInset(for: lineHeight) * 2)
            state.visibleTextHeight = availableTextHeight
            state.contentHeight = max(lineHeight, renderCache.layout.totalHeight)
            state.maxScrollY = max(0, state.contentHeight - state.visibleTextHeight)
            state.scrollOffsetY = clamp(state.scrollOffsetY, 0, state.maxScrollY)
            node.contentOffset = CGPoint(x: 0, y: CGFloat(state.scrollOffsetY))
        }

        func interactiveLayout(in text: String,
                               node: Node,
                               env: TextEnvironment,
                               font: Font,
                               lineHeight: Float) -> TextLayoutResult {
            let insetX = textField.horizontalInset(theme: node.theme)
            let addonLeading = textField.leadingAddonWidth(env: env,
                                                           font: font,
                                                           lineHeight: lineHeight,
                                                           theme: node.theme)
            let addonTrailing = textField.trailingAddonWidth(env: env,
                                                             font: font,
                                                             lineHeight: lineHeight,
                                                             theme: node.theme)
            let availableTextWidth = max(0,
                                         Float(node.frame.width)
                                         - insetX * 2
                                         - addonLeading
                                         - addonTrailing)
            return env.cachedLayout(text: text,
                                    font: font,
                                    lineHeight: lineHeight,
                                    maxWidth: layoutMaxWidth(for: text,
                                                             availableTextWidth: availableTextWidth),
                                    alignment: .leading)
        }

        func layoutMaxWidth(for text: String, availableTextWidth: Float) -> Float {
            guard textField.axis == .vertical else { return .infinity }
            return max(1, availableTextWidth)
        }

        func characterBoundaryUTF8Offsets(in text: String) -> [Int] {
            var offsets: [Int] = []
            offsets.reserveCapacity(text.count + 1)
            var running = 0
            for character in text {
                offsets.append(running)
                running += String(character).utf8.count
            }
            offsets.append(running)
            return offsets
        }

        func characterIndex(forUTF8Offset offset: Int, boundaries: [Int]) -> Int {
            guard let last = boundaries.last else { return 0 }
            let bounded = clamp(offset, 0, last)
            var low = 0
            var high = max(0, boundaries.count - 1)
            while low < high {
                let mid = (low + high + 1) / 2
                if boundaries[mid] <= bounded {
                    low = mid
                } else {
                    high = mid - 1
                }
            }
            return low
        }
    }
}