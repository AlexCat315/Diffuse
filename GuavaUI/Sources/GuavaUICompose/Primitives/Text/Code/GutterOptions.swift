public import GuavaUIRuntime

public struct TextBreakpoint: Equatable, Sendable {
    public enum State: Equatable, Sendable { case enabled, disabled, unverified }
    /// Zero-based logical source line, independent of wrapping and folding.
    public var line: Int
    public var state: State
    public init(line: Int, state: State = .enabled) { self.line = line; self.state = state }
}

/// Optional caller-owned document-session annotations. This value is deliberately
/// separate from source text, undo snapshots and persisted project configuration.
public struct TextEditorAnnotations: Equatable, Sendable {
    public var breakpoints: [TextBreakpoint] = []
    public var collapsedLines: Set<Int> = []
    public init() {}
    public mutating func rebase(from previous: TextBuffer, to next: TextBuffer) {
        guard previous != next else { return }
        guard let change = TextLineRebase(previous, next) else {
            if !previous.hasSameContents(as: next) { self = .init() }; return
        }
        breakpoints = breakpoints.compactMap { point in
            guard let line = change.line(point.line), line >= 0, line < next.lineCount else { return nil }
            return TextBreakpoint(line: line, state: point.state)
        }
        collapsedLines = Set(collapsedLines.compactMap { change.line($0) }.filter { $0 >= 0 && $0 < next.lineCount })
    }
}

public struct TextGutterMarker: Identifiable {
    public let id: String
    public var line: Int
    public var label: String
    public var icon: BundleImageResource
    public var color: Color?
    public var action: () -> Void
    public init(_ id: String, line: Int, label: String, icon: BundleImageResource,
                color: Color? = nil, action: @escaping () -> Void) {
        self.id = id; self.line = line; self.label = label; self.icon = icon; self.color = color; self.action = action
    }
}

/// Names are functions so applications can localize word order and line numbers.
public struct TextGutterLabels {
    public var lineActions: (Int) -> String = { "Line \($0 + 1) actions" }
    public var addBreakpoint: (Int) -> String = { "Add breakpoint at line \($0 + 1)" }
    public var removeBreakpoint: (Int) -> String = { "Remove breakpoint at line \($0 + 1)" }
    public var enableBreakpoint: (Int) -> String = { "Enable breakpoint at line \($0 + 1)" }
    public var disableBreakpoint: (Int) -> String = { "Disable breakpoint at line \($0 + 1)" }
    public var execution: (Int) -> String = { "Execution paused at line \($0 + 1)" }
    public var breakpointState: (TextBreakpoint.State) -> String = {
        switch $0 { case .enabled: "Enabled"; case .disabled: "Disabled"; case .unverified: "Unverified" }
    }
    public init() {}
}

/// Breakpoints belong to the caller's document session, never the source text.
/// Editing rebases them; callbacks can forward the resulting list to a debugger.
public struct TextEditorGutter {
    public var breakpoints: Binding<[TextBreakpoint]>?
    public var onBreakpointsChange: (([TextBreakpoint]) -> Void)?
    public var markers: [TextGutterMarker] = []
    public var executionLine: Int?
    public var labels = TextGutterLabels()
    public init() {}
    var isEnabled: Bool { breakpoints != nil || !markers.isEmpty || executionLine != nil }
}
