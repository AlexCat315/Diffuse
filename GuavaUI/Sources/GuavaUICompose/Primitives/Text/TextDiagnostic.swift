import Foundation
import GuavaUIRuntime

public struct TextDiagnostic: Equatable, Sendable {
    public enum Severity: Sendable { case error, warning, information, hint }
    public let utf8Range: Range<Int>
    public let severity: Severity
    public let message: String
    public init(utf8Range: Range<Int>, severity: Severity, message: String) {
        self.utf8Range = utf8Range; self.severity = severity; self.message = message
    }
}

/// An immutable interval index. Build when a diagnostic reply changes; paint
/// and hover query only overlapping ranges, including zero-width diagnostics.
public struct TextDiagnostics: Sendable, Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.root === rhs.root }
    public static let empty = TextDiagnostics([])
    private let root: DiagnosticInterval?
    public init(_ diagnostics: [TextDiagnostic]) {
        root = DiagnosticInterval.build(diagnostics.sorted { $0.utf8Range.lowerBound < $1.utf8Range.lowerBound })
    }
    public func overlapping(_ range: Range<Int>) -> [TextDiagnostic] {
        var result: [TextDiagnostic] = []; root?.collect(range, into: &result); return result
    }
}
private final class DiagnosticInterval: Sendable {
    let value: TextDiagnostic
    let left: DiagnosticInterval?
    let right: DiagnosticInterval?
    let maximumEnd: Int
    init(value: TextDiagnostic, left: DiagnosticInterval?, right: DiagnosticInterval?) {
        self.value = value; self.left = left; self.right = right
        maximumEnd = max(value.utf8Range.lowerBound + 1, value.utf8Range.upperBound,
                         left?.maximumEnd ?? 0, right?.maximumEnd ?? 0)
    }
    static func build(_ values: [TextDiagnostic]) -> DiagnosticInterval? {
        func subtree(_ range: Range<Int>) -> DiagnosticInterval? {
            guard !range.isEmpty else { return nil }
            let middle = range.lowerBound + range.count / 2
            return DiagnosticInterval(value: values[middle], left: subtree(range.lowerBound..<middle),
                                      right: subtree((middle + 1)..<range.upperBound))
        }
        return subtree(values.indices)
    }
    func collect(_ range: Range<Int>, into result: inout [TextDiagnostic]) {
        guard maximumEnd > range.lowerBound else { return }
        left?.collect(range, into: &result)
        guard value.utf8Range.lowerBound < range.upperBound else { return }
        if max(value.utf8Range.upperBound, value.utf8Range.lowerBound + 1) > range.lowerBound { result.append(value) }
        right?.collect(range, into: &result)
    }
}

struct TextDiagnosticSegment {
    let diagnostic: TextDiagnostic
    let x: Float
    let width: Float
    let baselineY: Float
}
enum TextDiagnosticGeometry {
    static func segments(in layout: TextLayoutResult, diagnostics: TextDiagnostics, lineHeight: Float) -> [TextDiagnosticSegment] {
        layout.lines.flatMap { line in
            let first = Int(line.startCluster), last = Int(line.endCluster)
            return diagnostics.overlapping(first..<max(first + 1, last)).map { diagnostic in
                func x(_ byte: Int) -> Float {
                    if byte <= first { return 0 }
                    if byte >= last { return line.width }
                    // A multi-byte or multi-glyph cluster is one underline span.
                    let before = line.glyphs.last { Int($0.cluster) <= byte }
                    return before?.x ?? 0
                }
                let lower = x(max(first, diagnostic.utf8Range.lowerBound))
                let upperByte = min(last, diagnostic.utf8Range.upperBound)
                let upper = upperByte >= last ? line.width
                    : (line.glyphs.first { Int($0.cluster) >= upperByte }?.x ?? line.width)
                return TextDiagnosticSegment(diagnostic: diagnostic, x: lower, width: max(6, upper - lower),
                                             baselineY: line.topY + lineHeight - 2)
            }
        }
    }
    static func draw(_ segments: [TextDiagnosticSegment], origin: (Float, Float), opacity: Float, theme: Theme, list: DrawList) {
        for segment in segments {
            let color: Color = switch segment.diagnostic.severity {
            case .error: theme.colors.error
            case .warning: theme.colors.warning
            case .information: theme.colors.accent
            case .hint: theme.colors.onSurfaceMuted
            }
            let start = origin.0 + segment.x, y = origin.1 + segment.baselineY
            var x = start, up = false
            while x < start + segment.width {
                let end = min(start + segment.width, x + 2)
                list.addLine(fromX: x, fromY: y + (up ? 0 : 1.5), toX: end, toY: y + (up ? 1.5 : 0),
                             thickness: 1, color: color.multipliedAlpha(opacity))
                x = end; up.toggle()
            }
        }
    }
}
