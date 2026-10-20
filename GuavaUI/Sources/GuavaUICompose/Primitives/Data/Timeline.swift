import Foundation
import GuavaUIRuntime

/// One entry in a `Timeline`.
public struct TimelineEvent: Identifiable {
    public let id: String
    public var title: String
    public var detail: String
    /// Trailing metadata: a timestamp, duration or actor. Moves below the title
    /// when this timeline's content width is compact or both labels cannot fit.
    public var trailing: String
    public var tone: StatusTone
    /// Glyph override. `nil` uses the tone's glyph; set `showsIcon = false`
    /// for a plain dot.
    public var icon: BundleImageResource?
    public var showsIcon: Bool
    /// Draws a plain dot instead of a glyph, for dense or low-signal entries.
    public var isCompact: Bool
    /// When the event happened. Proportional spacing uses the gaps between
    /// consecutive dates; events without one keep uniform spacing.
    public var date: Date?

    public init(_ title: String,
                id: String? = nil,
                detail: String = "",
                trailing: String = "",
                tone: StatusTone = .neutral,
                icon: BundleImageResource? = nil,
                showsIcon: Bool = true,
                isCompact: Bool = false,
                date: Date? = nil) {
        self.id = id ?? title
        self.title = title
        self.detail = detail
        self.trailing = trailing
        self.tone = tone
        self.icon = icon
        self.showsIcon = showsIcon
        self.isCompact = isCompact
        self.date = date
    }
}

/// A titled run of events that can collapse to its header.
public struct TimelineGroup: Identifiable {
    public let id: String
    public var title: String
    public var events: [TimelineEvent]
    public var isCollapsible = true
    public init(_ title: String, id: String? = nil, events: [TimelineEvent],
                configure: (inout Self) -> Void = { _ in }) {
        self.id = id ?? title; self.title = title; self.events = events
        configure(&self)
    }
}

/// Vertical distance between consecutive events.
public enum TimelineSpacing: Equatable, Sendable {
    /// One theme gap between entries: a sequence, not a time scale.
    case uniform
    /// Extra gap proportional to the time between dated events, clamped to
    /// `minimum...maximum` points, then multiplied by the zoom factor.
    case proportional(pointsPerHour: Float, minimum: Float = 0, maximum: Float = 240)

    func gap(from earlier: Date?, to later: Date?, zoom: Float) -> Float {
        guard case let .proportional(perHour, minimum, maximum) = self, let earlier, let later else { return 0 }
        let hours = Float(abs(later.timeIntervalSince(earlier)) / 3600)
        return max(minimum, min(maximum, hours * perHour)) * zoom
    }
}

/// Zoom range for proportional spacing. The binding is the caller's view
/// state; Timeline adds zoom buttons only when one is supplied.
public struct TimelineZoom {
    public var factor: Binding<Float>
    public var range: ClosedRange<Float> = 0.25...8
    public init(_ factor: Binding<Float>) { self.factor = factor }
    func clamped(_ value: Float) -> Float { min(range.upperBound, max(range.lowerBound, value.isFinite ? value : 1)) }
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
///
/// Titled `TimelineGroup`s get a disclosure header that collapses the group;
/// `spacing = .proportional(...)` spaces dated events by elapsed time, and a
/// `zoom` binding scales that spacing with built-in zoom controls.
public struct Timeline: View {
    public var groups: [TimelineGroup]
    /// Hides the connector line on the final entry, which is the default: the
    /// sequence ends where the list ends.
    public var showsTrailingConnector: Bool
    public var spacing: TimelineSpacing = .uniform
    public var zoom: TimelineZoom?
    /// Collapsed group IDs; session-local when `nil`.
    public var collapsedGroups: Binding<Set<String>>?
    @State private var localCollapsed: Set<String> = []

    public init(events: [TimelineEvent],
                configure: (inout Self) -> Void = { _ in }) {
        self.init(groups: [TimelineGroup("", id: "timeline.events", events: events)], configure: configure)
    }

    public init(groups: [TimelineGroup],
                configure: (inout Self) -> Void = { _ in }) {
        self.groups = groups
        self.showsTrailingConnector = false
        configure(&self)
    }

    /// Every event in display order, across groups.
    public var events: [TimelineEvent] { groups.flatMap(\.events) }

    private var collapsed: Binding<Set<String>> { collapsedGroups ?? $localCollapsed }

    public var body: some View {
        ThemeReader { theme in
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                if let zoom { zoomControls(zoom) }
                for (groupIndex, group) in groups.enumerated() {
                    AnyView(groupView(group, isLastGroup: groupIndex == groups.count - 1, theme: theme).id(group.id))
                }
            }
            .accessibility { $0.role = .list }
        }
    }

    private func groupView(_ group: TimelineGroup, isLastGroup: Bool, theme: Theme) -> some View {
        let isCollapsed = !group.title.isEmpty && group.isCollapsible && collapsed.wrappedValue.contains(group.id)
        let factor = zoom.map { $0.clamped($0.factor.wrappedValue) } ?? 1
        return Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if !group.title.isEmpty {
                TimelineGroupHeader(group: group, isCollapsed: isCollapsed) {
                    if collapsed.wrappedValue.contains(group.id) { collapsed.wrappedValue.remove(group.id) }
                    else { collapsed.wrappedValue.insert(group.id) }
                }
                .padding(EdgeInsets(bottom: isCollapsed ? (isLastGroup ? 0 : theme.spacing.sm) : theme.spacing.xs))
            }
            if !isCollapsed {
                for (index, event) in group.events.enumerated() {
                    let isLast = isLastGroup && index == group.events.count - 1
                    let next = index + 1 < group.events.count ? group.events[index + 1] : nil
                    let gap = index == group.events.count - 1
                        ? (isLastGroup ? 0 : theme.spacing.sm)
                        : theme.spacing.sm + spacing.gap(from: event.date, to: next?.date, zoom: factor)
                    AnyView(_TimelineRow(event: event,
                                         isLast: isLast,
                                         showsTrailingConnector: showsTrailingConnector)
                        .padding(EdgeInsets(bottom: gap))
                        .id(event.id))
                }
            }
        }
    }

    private func zoomControls(_ zoom: TimelineZoom) -> some View {
        let factor = zoom.clamped(zoom.factor.wrappedValue)
        return Row(alignment: .center, spacing: 4) {
            Spacer()
            Button(icon: .resource(UIIcons.Action.minus), size: 12, isEnabled: factor > zoom.range.lowerBound,
                   tooltip: "Zoom out") { zoom.factor.wrappedValue = zoom.clamped(factor / 2) }
                .buttonStyle(.ghost).accessibilityLabel("Zoom out")
            Text("\(Int((factor * 100).rounded()))%").font(.caption).foregroundColor(.onSurfaceMuted)
                .accessibility { $0.role = .status; $0.label = "Zoom"; $0.value = "\(Int((factor * 100).rounded())) percent" }
            Button(icon: .resource(UIIcons.Action.plus), size: 12, isEnabled: factor < zoom.range.upperBound,
                   tooltip: "Zoom in") { zoom.factor.wrappedValue = zoom.clamped(factor * 2) }
                .buttonStyle(.ghost).accessibilityLabel("Zoom in")
        }
        .padding(EdgeInsets(bottom: 4))
        .accessibility { $0.role = .toolbar; $0.label = "Timeline zoom" }
    }
}

/// Group disclosure: full-width button with the title, event count and a
/// chevron; expanded state is exposed to assistive technology.
private struct TimelineGroupHeader: View {
    let group: TimelineGroup
    let isCollapsed: Bool
    let toggle: () -> Void
    var body: some View {
        let count = "\(group.events.count)"
        let label = Row(alignment: .center, spacing: 6) {
            if group.isCollapsible {
                Icon(isCollapsed ? UIIcons.Navigation.chevronRight : UIIcons.Navigation.chevronDown, size: .small)
                    .accessibilityHidden()
            }
            Text(group.title).font(.bodyStrong).foregroundColor(.onSurface).flex(1, shrink: 1).frame(minWidth: 0)
            Badge(count, tone: .neutral).accessibilityHidden()
        }.frame(minHeight: 28)
        if !group.isCollapsible {
            return AnyView(label.accessibility { $0.role = .heading; $0.label = group.title; $0.value = "\(count) events"; $0.combinesChildren = true })
        }
        return AnyView(Button(action: toggle) { label }
            .buttonStyle(.ghost)
            .compositionLocal(ActionControlAccessibility.label, group.title)
            .compositionLocal(ActionControlAccessibility.value, "\(count) events")
            .compositionLocal(ActionControlAccessibility.isExpanded, !isCollapsed))
    }
}

private struct _TimelineRow: View {
    let event: TimelineEvent
    let isLast: Bool
    let showsTrailingConnector: Bool

    var body: some View {
        ThemeReader { theme in
            IconMetricsReader { metrics in
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
                .frame(width: max(22, metrics.size(.medium)))
                Box(direction: .column, alignItems: .stretch, spacing: 2) {
                    TimelineHeadingLayout(spacing: theme.spacing.sm) {
                        Text(event.title).font(.bodyStrong).foregroundColor(.onSurface)
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
            .accessibility {
                $0.role = .listItem; $0.label = event.title
                $0.value = event.trailing; $0.help = event.detail
            }
            }
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
