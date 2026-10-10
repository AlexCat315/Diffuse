import GuavaUIRuntime

/// One line of persistent context at the bottom of a window.
///
/// A status bar is the only chrome in a window that is allowed to hold many
/// small facts at once — cursor position, encoding, branch, connection state —
/// so it enforces the two things that keep such a row legible: a single height
/// for every cell, and leading/trailing slots that never fight for space.
///
/// ```swift
/// StatusBar {
///     StatusBarText("main", icon: UIIcons.Development.gitBranch)
///     StatusBarText("UTF-8", isMonospaced: true)
/// } trailing: {
///     StatusBarText("Ln 42, Col 7", isMonospaced: true)
///     StatusBarText("Connected", tone: .success)
/// }
/// ```
public enum StatusBarMetrics {
    /// Shared height, so a status bar swapping cells never changes the window's
    /// content height and never reflows the view above it.
    public static let height: Float = 26
}

public struct StatusBar<Leading: View, Trailing: View>: View {
    public let leading: Leading
    public let trailing: Trailing
    /// The hairline that separates the bar from the content above it.
    public var showsDivider: Bool
    public var isEnabled: Bool

    public init(showsDivider: Bool = true,
                isEnabled: Bool = true,
                @ViewBuilder leading: () -> Leading,
                @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
        self.showsDivider = showsDivider
        self.isEnabled = isEnabled
    }

    public var body: some View {
        ThemeReader { theme in
            Column(spacing: 0) {
                if showsDivider { AnyView(Divider()) }
                AnyView(Box(direction: .row, alignItems: .center, spacing: theme.spacing.md) {
                    AnyView(leading)
                    AnyView(Spacer())
                    AnyView(trailing)
                }
                .frame(height: StatusBarMetrics.height)
                .padding(horizontal: theme.spacing.md)
                .background(theme.colors.surfaceRaised)
                .opacity(isEnabled ? 1 : 0.6))
            }
            .accessibility { $0.role = .group; $0.label = "Status bar"; $0.state.isEnabled = isEnabled }
        }
    }
}

public extension StatusBar where Trailing == EmptyView {
    init(showsDivider: Bool = true,
         isEnabled: Bool = true,
         @ViewBuilder leading: () -> Leading) {
        self.init(showsDivider: showsDivider, isEnabled: isEnabled, leading: leading) { EmptyView() }
    }
}

public extension StatusBar where Leading == EmptyView {
    init(showsDivider: Bool = true,
         isEnabled: Bool = true,
         @ViewBuilder trailing: () -> Trailing) {
        self.init(showsDivider: showsDivider, isEnabled: isEnabled, leading: { EmptyView() }, trailing: trailing)
    }
}

/// A single status-bar cell: one short fact, optionally toned and optionally
/// monospaced so numbers stay column-aligned while they change.
public struct StatusBarText: View {
    public var text: String
    /// Secondary value appended in a dimmer ink: `Ln 42` + `Col 7`.
    public var detail: String
    public var icon: BundleImageResource?
    /// `nil` reads as neutral context; a tone marks the fact as a state worth
    /// noticing (disconnected, unsaved, failing).
    public var tone: StatusTone?
    public var isMonospaced: Bool

    public init(_ text: String,
                detail: String = "",
                icon: BundleImageResource? = nil,
                tone: StatusTone? = nil,
                isMonospaced: Bool = false) {
        self.text = text
        self.detail = detail
        self.icon = icon
        self.tone = tone
        self.isMonospaced = isMonospaced
    }

    public var body: some View {
        ThemeReader { theme in
            let ink = tone?.color.resolve(theme) ?? theme.colors.onSurfaceVariant
            Row(alignment: .center, spacing: 4) {
                if let icon { Icon(icon, size: 11, color: ink) }
                Text(text)
                    .font(isMonospaced ? .mono : .caption)
                    .foregroundColor(ink)
                if !detail.isEmpty {
                    Text(detail)
                        .font(isMonospaced ? .mono : .caption)
                        .foregroundColor(theme.colors.onSurfaceMuted)
                }
            }
            .accessibility { $0.role = .staticText; $0.value = [text, detail].filter { !$0.isEmpty }.joined(separator: ", ") }
        }
    }
}
