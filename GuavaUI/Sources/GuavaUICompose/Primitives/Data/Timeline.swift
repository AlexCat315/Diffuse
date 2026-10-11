import GuavaUIRuntime

/// One entry in a `Timeline`.
public struct TimelineEvent: Identifiable {
    public let id: String
    public var title: String
    public var detail: String
    /// Right-aligned meta: a timestamp, a duration, an actor.
    public var trailing: String
    public var tone: StatusTone
    /// Glyph override. `nil` uses the tone's glyph; set `showsIcon = false`
    /// for a plain dot.
    public var icon: BundleImageResource?
    public var showsIcon: Bool
    /// Draws a plain dot instead of a glyph, for dense or low-signal entries.
    public var isCompact: Bool

    public init(_ title: String,
                id: String? = nil,
                detail: String = "",
                trailing: String = "",
                tone: StatusTone = .neutral,
                icon: BundleImageResource? = nil,
                showsIcon: Bool = true,
                isCompact: Bool = false) {
        self.id = id ?? title
        self.title = title
        self.detail = detail
        self.trailing = trailing
        self.tone = tone
        self.icon = icon
        self.showsIcon = showsIcon
        self.isCompact = isCompact
    }
}

/// Ordered list of events on a vertical rail.
///
/// The rail is the content: the connector line is what turns a stack of rows
/// into a sequence, and the glyph on each node is what lets the reader scan by
/// outcome (failed, succeeded, pending) before reading a single title.
///
/// ```swift
/// Timeline(events: [
///     TimelineEvent("Build started", trailing: "09:12", tone: .info),
///     TimelineEvent("Shader compiled", trailing: "09:12", tone: .success),
///     TimelineEvent("Link failed", detail: "Undefined symbol: vkCreateBuffer",
///                   trailing: "09:14", tone: .danger)
/// ])
/// ```
public struct Timeline: View {
    public var events: [TimelineEvent]
    /// Hides the connector line on the final entry, which is the default: the
    /// sequence ends where the list ends.
    public var showsTrailingConnector: Bool

    public init(events: [TimelineEvent],
                configure: (inout Self) -> Void = { _ in }) {
        self.events = events
        self.showsTrailingConnector = false
        configure(&self)
    }

    public var body: some View {
        ThemeReader { theme in
            Column(alignment: .leading, spacing: 0) {
                for (index, event) in events.enumerated() {
                    AnyView(_TimelineRow(event: event,
                                         isLast: index == events.count - 1,
                                         showsTrailingConnector: showsTrailingConnector)
                        .padding(EdgeInsets(bottom: index == events.count - 1 ? 0 : theme.spacing.sm)))
                }
            }
            .accessibility { $0.role = .list }
        }
    }
}

private struct _TimelineRow: View {
    let event: TimelineEvent
    let isLast: Bool
    let showsTrailingConnector: Bool

    var body: some View {
        ThemeReader { theme in
            Box(direction: .row, alignItems: .stretch, spacing: theme.spacing.sm) {
                Box(direction: .column, alignItems: .center, spacing: 4) {
                    AnyView(node(theme))
                    if !isLast || showsTrailingConnector {
                        AnyView(Box(direction: .row) { EmptyView() }
                            .frame(width: 1)
                            .flex(1, shrink: 1, basis: 0)
                            .background(SemanticColorRef.border))
                    }
                }
                .frame(width: 22)
                Column(alignment: .leading, spacing: 2) {
                    Row(alignment: .center, spacing: theme.spacing.sm) {
                        Text(event.title).font(.bodyStrong).foregroundColor(.onSurface)
                            .flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
                        if !event.trailing.isEmpty {
                            Text(event.trailing).font(.caption).foregroundColor(.onSurfaceMuted)
                        }
                    }
                    if !event.detail.isEmpty {
                        Text(event.detail).font(.body).foregroundColor(.onSurfaceVariant)
                    }
                }
                .flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
            }
            .accessibility { $0.role = .listItem; $0.label = event.title; $0.help = event.detail }
        }
    }

    @ViewBuilder private func node(_ theme: Theme) -> some View {
        if event.isCompact || !event.showsIcon {
            Box(direction: .row) { EmptyView() }
                .frame(width: 7, height: 7)
                .background(event.tone.color)
                .cornerRadius(3.5)
                .accessibilityHidden()
        } else {
            Icon(event.icon ?? event.tone.icon, size: .medium, color: event.tone.color)
                .accessibilityHidden()
        }
    }
}
