public import GuavaUIRuntime

/// Retains the header line and hides the following lines through the closing line.
public struct TextFoldRegion: Equatable, Sendable {
    public var lines: ClosedRange<Int>
    public init(lines: ClosedRange<Int>) { self.lines = lines }
}

public struct TextFoldingLabels {
    public var collapse: (Int) -> String = { "Collapse code at line \($0 + 1)" }
    public var expand: (Int) -> String = { "Expand code at line \($0 + 1)" }
    public var summary: (Int) -> String = { "\($0) folded lines" }
    public var hiddenBreakpoints: (Int) -> String = { "\($0) breakpoints in folded code" }
    public init() {}
}

/// Language services supply logical regions; the field owns only presentation.
/// Omit collapsedLines for a node-local session, or bind it to caller-owned state.
public struct TextEditorFolding {
    public var regions: [TextFoldRegion] = []
    /// False while an asynchronous language service is producing its snapshot.
    /// Pending ranges must not erase caller-owned collapsed headers on remount.
    public var isReady = true
    public var collapsedLines: Binding<Set<Int>>?
    public var labels = TextFoldingLabels()
    public init() {}
}

struct TextLineRebase {
    let first: Int
    let last: Int
    let newLast: Int
    let startsAtLineStart: Bool
    init?(_ previous: TextBuffer, _ next: TextBuffer) {
        guard let edit = next.editDelta(from: previous) else { return nil }
        first = previous.lineIndex(forCharacterIndex: edit.characterRange.lowerBound)
        last = previous.lineIndex(forCharacterIndex: edit.characterRange.upperBound)
        newLast = next.lineIndex(forCharacterIndex: next.characterIndex(forUTF8Offset: edit.newEndUTF8Offset))
        startsAtLineStart = edit.characterRange.lowerBound == previous.lineRange(forLine: first).lowerBound
    }
    func line(_ line: Int) -> Int? {
        if line < first { return line }
        if line == first {
            if !startsAtLineStart { return line }
            return first == last ? newLast : nil
        }
        if line < last { return nil }
        return line + newLast - last
    }
}

final class TextFoldSession {
    private(set) var regions: [Int: TextFoldRegion] = [:]
    private(set) var collapsed: Set<Int> = []
    private var authored: [TextFoldRegion] = []
    private var buffer: TextBuffer?
    private var binding: Binding<Set<Int>>?
    private var previousBound: Set<Int> = []
    private(set) var hiddenLines: [Range<Int>] = []
    private func updateProjection() {
        var result: [Range<Int>] = []
        for header in collapsed.sorted() {
            guard let region = regions[header] else { continue }
            let range = (header + 1)..<(region.lines.upperBound + 1)
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { result.append(range) }
        }
        hiddenLines = result
    }
    func synchronize(_ options: TextEditorFolding, buffer next: TextBuffer) {
        let previousCollapsed = collapsed
        let projectionChanged = buffer != next || authored != options.regions
        binding = options.collapsedLines
        if let binding { collapsed = binding.wrappedValue }
        if let buffer, buffer != next {
            if let change = TextLineRebase(buffer, next) {
                if binding == nil || collapsed == previousBound { collapsed = Set(collapsed.compactMap { change.line($0) }) }
                regions = Dictionary(regions.values.compactMap { region -> (Int, TextFoldRegion)? in
                    guard let start = change.line(region.lines.lowerBound),
                          let end = change.line(region.lines.upperBound), start < end else { return nil }
                    return (start, TextFoldRegion(lines: start...end))
                }, uniquingKeysWith: { first, _ in first })
            } else if !buffer.hasSameContents(as: next) { collapsed = []; regions = [:] }
        }
        if self.buffer == nil || authored != options.regions {
            regions = [:]
            // One outermost range per header. Crossing regions are discarded;
            // properly nested regions retain their own collapsed session.
            var ancestors: [TextFoldRegion] = []
            for region in options.regions.sorted(by: {
                $0.lines.lowerBound == $1.lines.lowerBound ? $0.lines.upperBound > $1.lines.upperBound : $0.lines.lowerBound < $1.lines.lowerBound
            }) {
                let first = region.lines.lowerBound, last = region.lines.upperBound
                guard first >= 0, first < last, last < next.lineCount, regions[first] == nil else { continue }
                while let parent = ancestors.last, first > parent.lines.upperBound { ancestors.removeLast() }
                if let parent = ancestors.last, last > parent.lines.upperBound { continue }
                regions[first] = region; ancestors.append(region)
            }
            authored = options.regions
        }
        if options.isReady { collapsed.formIntersection(regions.keys) }
        if let binding, binding.wrappedValue != collapsed { binding.wrappedValue = collapsed }
        previousBound = collapsed
        buffer = next
        if projectionChanged || previousCollapsed != collapsed { updateProjection() }
    }
    func toggle(_ line: Int) {
        guard regions[line] != nil else { return }
        if !collapsed.insert(line).inserted { collapsed.remove(line) }
        binding?.wrappedValue = collapsed
        updateProjection()
    }
    func reveal(_ line: Int) -> Bool {
        let enclosing = collapsed.filter { regions[$0]?.lines.contains(line) == true && $0 != line }
        guard !enclosing.isEmpty else { return false }
        collapsed.subtract(enclosing); binding?.wrappedValue = collapsed; updateProjection(); return true
    }
}
