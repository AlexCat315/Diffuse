internal import GuavaUIRuntime

extension TextField {
    func gutterGeometry(env: TextEnvironment, font: Font, lineHeight: Float, node: Node) -> TextGutterGeometry {
        let numbers = env.cachedLayout(text: String(repeating: "8", count: max(3, String(text.wrappedValue.lineCount).count)),
                                      font: font, lineHeight: lineHeight, maxWidth: .infinity, alignment: .trailing)
        return TextGutterGeometry(field: self, numberWidth: numbers.totalWidth, font: font, theme: node.theme,
                                  touch: node.compositionValue(of: SurfaceEnvironment.key).input.contains(.touch))
    }
    func gutterNumberRight(env: TextEnvironment, font: Font, lineHeight: Float, node: Node) -> Float {
        gutterGeometry(env: env, font: font, lineHeight: lineHeight, node: node).numberRight
    }
    func updateGutterControls(_ layout: TextLayoutResult, source: TextBuffer, textOriginX: Float,
                              textOriginY: Float, origin: CGPoint, lineHeight: Float, node: Node,
                              env: TextEnvironment, font: Font, list: DrawList) {
        guard let session = node.firstResource(TextGutterSession.self) else { return }
        guard codeEditing.showsLineNumbers, self.layout.axis == .vertical, !behavior.secure,
              (node.attachments["__textfield_state"] as? FieldState)?.composition.isActive != true,
              codeEditing.gutter.isEnabled || !codeEditing.folding.regions.isEmpty else { session.update([]); return }
        let geometry = gutterGeometry(env: env, font: font, lineHeight: lineHeight, node: node)
        let x = textOriginX - Float(origin.x) - geometry.width
        var controls: [TextGutterControl] = [], lastLine = -1
        for row in layout.lines {
            let line = source.lineIndex(forCharacterIndex: source.characterIndex(forUTF8Offset: Int(row.startCluster)))
            guard line != lastLine else { continue }; lastLine = line
            let y = textOriginY - Float(origin.y) + row.topY
            // Partial rows remain visible text, but never expose clipped targets.
            guard y >= 0, y + lineHeight <= Float(node.frame.height) else { continue }
            if codeEditing.gutter.executionLine == line {
                list.addRect(.init(x: Float(origin.x), y: Float(origin.y) + y, width: Float(node.frame.width), height: lineHeight),
                             color: node.theme.colors.warning.multipliedAlpha(node.opacity * 0.10))
                list.addRect(.init(x: Float(origin.x), y: Float(origin.y) + y, width: 2, height: lineHeight),
                             color: node.theme.colors.warning.multipliedAlpha(node.opacity * 0.8))
                if codeEditing.gutter.breakpoints == nil, let lane = geometry.breakpointX {
                    let arrowX = Float(origin.x) + x + lane + 7, arrowY = Float(origin.y) + y + lineHeight / 2
                    list.addTriangle(arrowX, arrowY - 5, arrowX + 9, arrowY, arrowX, arrowY + 5,
                                     color: node.theme.colors.warning.multipliedAlpha(node.opacity))
                }
            }
            let controlHeight = geometry.combined ? lineHeight : min(lineHeight, 24)
            let top = y + (lineHeight - controlHeight) / 2
            if geometry.combined, codeEditing.gutter.breakpoints != nil || session.folds.regions[line] != nil || session.markersByLine[line]?.isEmpty == false {
                controls.append(.init(line: line, kind: .combined, x: x, y: top, width: 44, height: controlHeight))
            } else {
                if let lane = geometry.breakpointX, codeEditing.gutter.breakpoints != nil {
                    controls.append(.init(line: line, kind: .breakpoint, x: x + lane, y: top, width: 24, height: controlHeight))
                }
                if let lane = geometry.markerX, session.markersByLine[line]?.isEmpty == false {
                    controls.append(.init(line: line, kind: .markers, x: x + lane, y: top, width: 24, height: controlHeight))
                }
                if let lane = geometry.foldX, session.folds.regions[line] != nil {
                    controls.append(.init(line: line, kind: .fold, x: x + lane, y: top, width: 20, height: controlHeight))
                }
            }
            if let region = session.folds.regions[line], session.folds.collapsed.contains(line),
               let lastRow = layout.lines.last(where: {
                   source.lineIndex(forCharacterIndex: source.characterIndex(forUTF8Offset: Int($0.startCluster))) == line
               }) {
                let offset = (node.attachments["__textfield_state"] as? FieldState)?.scroll.horizontal.offset ?? 0
                let badgeX = textOriginX - Float(origin.x) - offset + lastRow.width + 8
                let width: Float = max(64, min(80, Float(node.frame.width) - badgeX - 8))
                if badgeX >= textOriginX - Float(origin.x), badgeX + width <= Float(node.frame.width) {
                    controls.append(.init(line: line, kind: .summary, x: badgeX,
                                          y: textOriginY - Float(origin.y) + lastRow.topY,
                                          width: width, height: lineHeight, count: region.lines.count - 1))
                }
            }
        }
        session.update(controls)
    }
}
