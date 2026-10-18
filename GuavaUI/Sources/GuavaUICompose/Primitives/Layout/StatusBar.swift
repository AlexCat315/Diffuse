import Foundation
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
                AnyView(StatusBarLayout(spacing: CGFloat(theme.spacing.md)) {
                    Row(alignment: .center, spacing: theme.spacing.md) { leading }.frame(minWidth: 0)
                    Row(alignment: .center, spacing: theme.spacing.md) { trailing }.frame(minWidth: 0)
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
                if let icon { Icon(icon, size: 11, color: ink).accessibilityHidden() }
                Text(text)
                    .truncatingTail()
                    .font(isMonospaced ? .mono : .caption)
                    .foregroundColor(ink)
                    .frame(minWidth: 0)
                    .flex(0, shrink: 1)
                if !detail.isEmpty {
                    Text(detail)
                        .truncatingTail()
                        .font(isMonospaced ? .mono : .caption)
                        .foregroundColor(theme.colors.onSurfaceMuted)
                        .frame(minWidth: 0)
                        .flex(0, shrink: 1)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .accessibility {
                $0.role = .staticText
                $0.label = text
                $0.value = [text, detail].filter { !$0.isEmpty }.joined(separator: ", ")
            }
        }
    }
}

private struct StatusBarLayout: Layout {
    var spacing: CGFloat
    /// Extra gutter beyond the authored spacing so a truncated leading cell
    /// cannot paint its clipped tail into the trailing state.
    private let trailingGap: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let trailing = safe(subviews[1].sizeThatFits(.unspecified))
        guard let width = proposal.width, width.isFinite else {
            let leading = safe(subviews[0].sizeThatFits(.unspecified))
            let usedWidth = leading.width + trailing.width + spacing
            return CGSize(width: usedWidth, height: max(leading.height, trailing.height))
        }
        let leadingWidth = max(0, width - trailing.width - spacing - trailingGap)
        let leading = leadingWidth > 0 ? safe(subviews[0].sizeThatFits(.init(width: leadingWidth))) : .zero
        return CGSize(width: max(0, width), height: max(leading.height, trailing.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        guard subviews.count == 2 else { return }
        let width = bounds.width.isFinite ? max(0, bounds.width) : 0
        let height = bounds.height.isFinite ? max(0, bounds.height) : 0
        let trailing = safe(subviews[1].sizeThatFits(.unspecified))
        let leadingWidth = max(0, width - trailing.width - spacing - trailingGap)
        let leading = leadingWidth > 0 ? safe(subviews[0].sizeThatFits(.init(width: leadingWidth))) : .zero
        let rtl = subviews.first?.layoutDirection == .rtl
        let leadingX = rtl ? bounds.minX + width - leading.width : bounds.minX
        let trailingX = rtl ? bounds.minX : bounds.minX + width - trailing.width
        let leadingY = bounds.minY + max(0, (height - leading.height) / 2)
        let trailingY = bounds.minY + max(0, (height - trailing.height) / 2)
        if leadingWidth > 0 {
            subviews[0].place(at: CGPoint(x: leadingX, y: leadingY),
                              proposal: .init(width: leadingWidth, height: leading.height))
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY),
                              proposal: .zero, isVisible: false)
        }
        if trailing.width > 0 {
            subviews[1].place(at: CGPoint(x: trailingX, y: trailingY),
                              proposal: .init(width: trailing.width, height: trailing.height))
        } else {
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY),
                              proposal: .zero, isVisible: false)
        }
    }

    private func safe(_ size: CGSize) -> CGSize {
        CGSize(width: size.width.isFinite ? max(0, size.width) : 0,
               height: size.height.isFinite ? max(0, size.height) : 0)
    }
}
