import GuavaUIRuntime

// Editor chrome building blocks for the modern-IDE shell: a vertical icon
// rail, pill-shaped output tabs, a slim status footer, and toolbar pills.
// All metrics follow the design spec (rail 40, rail button 30×30 with a
// 3×18 active accent bar, tab pills 24px with a 2px bottom accent, footer 24).

/// One item in a `ToolStripRail`.
public struct ToolStripItem: Sendable {
    public let id: String
    public let title: String
    /// Glyph shown in the 30×30 button (icon-font character or short text).
    public let glyph: String

    public init(id: String, title: String, glyph: String) {
        self.id = id
        self.title = title
        self.glyph = glyph
    }
}

/// Vertical 40px icon rail flanking the workspace. The active item gets an
/// accent-tinted background and a 3×18 accent bar on its leading edge.
public struct ToolStripRail: View {
    let top: [ToolStripItem]
    let bottom: [ToolStripItem]
    let activeID: String?
    let onSelect: (ToolStripItem) -> Void

    public init(top: [ToolStripItem],
                bottom: [ToolStripItem] = [],
                activeID: String?,
                onSelect: @escaping (ToolStripItem) -> Void) {
        self.top = top
        self.bottom = bottom
        self.activeID = activeID
        self.onSelect = onSelect
    }

    public var body: some View {
        Column(alignment: .center, spacing: 4) {
            for item in top {
                ToolStripButton(item: item,
                                isActive: item.id == activeID,
                                action: { onSelect(item) })
            }
            Spacer(minLength: 0)
            for item in bottom {
                ToolStripButton(item: item,
                                isActive: item.id == activeID,
                                action: { onSelect(item) })
            }
        }
        .padding(horizontal: 5, vertical: 6)
        .frame(width: 40)
    }
}

/// 30×30 rail button; active = accentMuted fill + leading 3×18 accent bar.
public struct ToolStripButton: View {
    let item: ToolStripItem
    let isActive: Bool
    let action: () -> Void

    public init(item: ToolStripItem, isActive: Bool, action: @escaping () -> Void) {
        self.item = item
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(tooltip: item.title, action: action) {
            Row(alignment: .center, spacing: 0) {
                Box { EmptyView() }
                    .frame(width: 3, height: 18)
                    .background(isActive ? SemanticColorRef.accent : .clearColor)
                Spacer(minLength: 0)
                Text(item.glyph)
                    .font(.label)
                    .foregroundColor(isActive ? .accent : .onSurfaceMuted)
                Spacer(minLength: 0)
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(_ToolStripButtonStyle(isActive: isActive))
    }
}

private struct _ToolStripButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let t = configuration.theme
        let clear = Color(r: 0, g: 0, b: 0, a: 0)
        let bg: Color = {
            if isActive { return t.colors.accentMuted }
            if configuration.isHovered { return t.colors.surfaceSunken }
            return clear
        }()
        return Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label)
        }
        .background(bg)
        .cornerRadius(6)
    }
}

/// Pill-shaped tab row for output/console panels: 24px pills, active =
/// elevated fill + accent stroke + 2px bottom accent bar.
public struct OutputTabBar: View {
    let tabs: [String]
    let active: String
    let onSelect: (String) -> Void

    public init(tabs: [String], active: String, onSelect: @escaping (String) -> Void) {
        self.tabs = tabs
        self.active = active
        self.onSelect = onSelect
    }

    public var body: some View {
        Row(alignment: .center, spacing: 8) {
            for tab in tabs {
                OutputTab(title: tab, isActive: tab == active, action: { onSelect(tab) })
            }
            Spacer(minLength: 0)
        }
        .padding(horizontal: 8, vertical: 5)
        .background(.surface)
    }
}

public struct OutputTab: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    public init(title: String, isActive: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Column(alignment: .center, spacing: 0) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(isActive ? .onSurface : .onSurfaceMuted)
                    .padding(horizontal: 12, vertical: 0)
                    .frame(height: 22)
                Box { EmptyView() }
                    .frame(height: 2)
                    .background(isActive ? SemanticColorRef.accent : SemanticColorRef.clearColor)
            }
        }
        .buttonStyle(_OutputTabStyle(isActive: isActive))
    }
}

private struct _OutputTabStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let t = configuration.theme
        let bg = isActive
            ? t.colors.surfaceSunken
            : t.colors.surface.multipliedAlpha(0.55)
        let stroke = isActive
            ? t.colors.accent.multipliedAlpha(0.68)
            : t.colors.border.multipliedAlpha(0.36)
        return Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label)
        }
        .background(bg)
        .cornerRadius(5)
        .border(stroke, width: 1)
        .opacity(configuration.isHovered && !isActive ? 0.85 : 1)
    }
}

/// 24px status footer: muted caption segments left and right.
public struct StatusFooter: View {
    let leading: [String]
    let trailing: [String]

    public init(leading: [String], trailing: [String] = []) {
        self.leading = leading
        self.trailing = trailing
    }

    public var body: some View {
        Row(alignment: .center, spacing: 16) {
            for segment in leading {
                AnyView(Text(segment).font(.caption).foregroundColor(.onSurfaceMuted))
            }
            Spacer(minLength: 0)
            for segment in trailing {
                AnyView(Text(segment).font(.caption).foregroundColor(.onSurfaceMuted))
            }
        }
        .padding(horizontal: 12, vertical: 0)
        .frame(height: 24)
    }
}

/// Toolbar pill: 28px rounded-7 chip; active = accent tint + accent text.
public struct ToolbarPill: View {
    let title: String
    let isActive: Bool

    public init(_ title: String, isActive: Bool = false) {
        self.title = title
        self.isActive = isActive
    }

    public var body: some View {
        _ToolbarPillBody(title: title, isActive: isActive)
    }
}

private struct _ToolbarPillBody: View {
    let title: String
    let isActive: Bool

    var body: some View {
        Text(title)
            .font(.label)
            .foregroundColor(isActive ? .accent : .onSurface)
            .padding(horizontal: 10, vertical: 0)
            .frame(height: 28)
            .background(isActive ? SemanticColorRef.accentMuted : SemanticColorRef.background)
            .cornerRadius(7)
            .border(.border, width: 1)
    }
}

private extension SemanticColorRef {
    static let clearColor = SemanticColorRef { _ in Color(r: 0, g: 0, b: 0, a: 0) }
}
