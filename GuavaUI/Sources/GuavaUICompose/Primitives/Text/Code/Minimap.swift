#if canImport(CoreGraphics)
import CoreGraphics
#endif
import GuavaUIRuntime

/// A scaled overview of a code field: every visual row as a two-point strip of
/// syntax-coloured bars, with the visible region marked. Taller documents
/// scroll the overview in step with the text, as editors commonly do.
extension TextField {
    static let minimapWidth: Float = 84
    private static let minimapRowHeight: Float = 2
    private static let minimapColumnWidth: Float = 1
    private static let minimapGeometryKey = "__textfield_minimap_geometry"

    /// Where the last frame drew the overview, for pointer hits and drags.
    struct MinimapGeometry {
        let rect: UIRect
        /// Overview points scrolled past its top.
        let scroll: Float
        let lineHeight: Float
    }

    var minimapReservation: Float {
        codeEditing.showsMinimap && layout.axis == .vertical ? Self.minimapWidth : 0
    }

    func drawMinimap(document: TextDocumentLayout, buffer: TextBuffer, state: FieldState, node: Node,
                     origin: CGPoint, lineHeight: Float, textColor: Color, list: DrawList) {
        guard minimapReservation > 0 else {
            node.attachments.removeValue(forKey: Self.minimapGeometryKey)
            return
        }
        let frameHeight = Float(node.frame.height)
        let rect = UIRect(x: Float(origin.x) + Float(node.frame.width) - Self.minimapWidth, y: Float(origin.y),
                          width: Self.minimapWidth, height: frameHeight)
        let rows = document.index.rowCount
        let overflow = max(0, Float(rows) * Self.minimapRowHeight - frameHeight)
        let progress = state.scroll.maxY > 0 ? min(1, state.scroll.offsetY / state.scroll.maxY) : 0
        let scroll = overflow * progress
        node.attachments[Self.minimapGeometryKey] = MinimapGeometry(rect: rect, scroll: scroll, lineHeight: lineHeight)

        list.pushClip(rect)
        defer { list.popClip() }
        let theme = node.theme
        let columns = Int(Self.minimapWidth / Self.minimapColumnWidth) - 4
        let first = max(0, Int(scroll / Self.minimapRowHeight))
        let last = min(rows, first + Int(frameHeight / Self.minimapRowHeight) + 2)
        let tabWidth = codeEditing.indentationWidth ?? 4
        if first < last {
            for row in first..<last {
                let location = document.index.location(atRow: row)
                guard location.subrow == 0 else { continue }
                let characters = buffer.lineRange(forLine: location.line)
                let start = buffer.utf8Offset(forCharacterIndex: characters.lowerBound)
                let end = min(buffer.utf8Offset(forCharacterIndex: characters.upperBound), start + columns)
                guard end > start else { continue }
                let bytes = buffer.utf8Bytes(inUTF8Range: start..<end)
                let y = rect.y + Float(row) * Self.minimapRowHeight - scroll
                var column = 0, runStart: Int?, runColumn = 0
                func flush(_ index: Int) {
                    guard let begin = runStart else { return }
                    let color = codeEditing.syntaxColorAtUTF8Offset?(buffer, start + begin) ?? textColor
                    list.addRect(UIRect(x: rect.x + 2 + Float(runColumn) * Self.minimapColumnWidth, y: y,
                                        width: Float(column - runColumn) * Self.minimapColumnWidth,
                                        height: Self.minimapRowHeight - 0.5),
                                 color: color.multipliedAlpha(node.opacity * 0.65))
                    runStart = nil
                }
                for (index, byte) in bytes.enumerated() {
                    // Continuation bytes belong to the character before them.
                    if byte & 0xC0 == 0x80 { continue }
                    if byte == 0x20 || byte == 0x09 {
                        flush(index)
                        column += byte == 0x09 ? tabWidth - column % tabWidth : 1
                    } else {
                        if runStart == nil { runStart = index; runColumn = column }
                        column += 1
                    }
                    if column >= columns { break }
                }
                flush(bytes.count)
            }
        }
        // The visible region, as one band over the rows it covers.
        let bandTop = rect.y + state.scroll.offsetY / max(1, lineHeight) * Self.minimapRowHeight - scroll
        let bandHeight = max(Self.minimapRowHeight * 2, state.scroll.visibleHeight / max(1, lineHeight) * Self.minimapRowHeight)
        list.addRect(UIRect(x: rect.x, y: bandTop, width: rect.width, height: bandHeight),
                     color: theme.colors.onSurface.multipliedAlpha(node.opacity * 0.08))
    }

    /// Whether `point` falls on the overview; if so, scrolls so the visible
    /// region centres on it. A drag that began on it follows the pointer anywhere.
    @discardableResult
    func scrollMinimap(to point: CGPoint, state: FieldState, node: Node, clampingX: Bool = true) -> Bool {
        guard let geometry = node.attachments[Self.minimapGeometryKey] as? MinimapGeometry else { return false }
        let x = Float(point.x), y = Float(point.y)
        if clampingX, x < geometry.rect.minX || x > geometry.rect.maxX || y < geometry.rect.minY || y > geometry.rect.maxY { return false }
        refreshScrollableMetrics(state: state, node: node)
        let row = (Float(point.y) - geometry.rect.y + geometry.scroll) / Self.minimapRowHeight
        let target = row * geometry.lineHeight - state.scroll.visibleHeight / 2
        state.scroll.offsetY = clamp(target, 0, state.scroll.maxY)
        state.scroll.needsCaretReveal = false
        node.contentOffset = CGPoint(x: CGFloat(state.scroll.horizontal.offset), y: CGFloat(state.scroll.offsetY))
        node.firstResource(TextCompletionSession.self)?.dismiss()
        reportHover(nil)
        node.markRenderDirty()
        return true
    }
}
