internal import GuavaUIRuntime

struct TextGutterGeometry {
    let width: Float
    let numberRight: Float
    let breakpointX: Float?
    let markerX: Float?
    let foldX: Float?
    let combined: Bool
    let controlWidth: Float

    init(field: TextField, numberWidth: Float, font: Font, theme: Theme, touch: Bool) {
        let gutter = field.codeEditing.gutter
        let folds = !field.codeEditing.folding.regions.isEmpty
        combined = touch && (gutter.isEnabled || folds)
        controlWidth = combined ? 44 : 24
        var leading: Float = 0
        if combined {
            breakpointX = 0; markerX = nil; foldX = nil; leading = 44
        } else {
            breakpointX = gutter.breakpoints != nil || gutter.executionLine != nil ? leading : nil
            if breakpointX != nil { leading += 24 }
            markerX = gutter.isEnabled ? leading : nil
            if markerX != nil { leading += 24 }
            foldX = folds ? leading + theme.spacing.lg + numberWidth + 4 : nil
        }
        numberRight = leading + theme.spacing.lg + numberWidth
        width = numberRight + max(max(theme.spacing.xxl, font.size), folds && !combined ? 36 : 0)
    }
}

struct TextGutterControl: Equatable, Identifiable {
    enum Kind: String { case breakpoint, markers, fold, combined, summary }
    let id: String
    let line: Int
    let kind: Kind
    let frame: CGRect
    let count: Int
    init(line: Int, kind: Kind, x: Float, y: Float, width: Float, height: Float, count: Int = 0) {
        self.id = "\(kind.rawValue)-\(line)"; self.line = line; self.kind = kind; self.count = count
        frame = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }
}
