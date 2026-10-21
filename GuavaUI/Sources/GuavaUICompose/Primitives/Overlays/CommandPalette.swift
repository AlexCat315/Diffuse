import Foundation
import GuavaUIRuntime

/// One entry in a `CommandPalette`.
///
/// `keywords` are the search-only aliases nobody sees — the abbreviation, the
/// old name, the menu path. Without them a palette only finds commands whose
/// title the user already remembers, which is exactly when they do not need one.
public struct CommandItem: Identifiable {
    public let id: String
    public var title: String
    public var subtitle: String
    /// Section heading. Items sharing a group are listed under one header.
    public var group: String
    public var keywords: [String]
    public var icon: BundleImageResource?
    public var shortcut: KeyboardShortcut?
    public var isEnabled: Bool
    public let action: () -> Void

    public init(_ title: String,
                id: String? = nil,
                subtitle: String = "",
                group: String = "",
                keywords: [String] = [],
                icon: BundleImageResource? = nil,
                shortcut: KeyboardShortcut? = nil,
                isEnabled: Bool = true,
                action: @escaping () -> Void) {
        self.id = id ?? title
        self.title = title
        self.subtitle = subtitle
        self.group = group
        self.keywords = keywords
        self.icon = icon
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// Searchable command surface presented as a modal overlay.
///
/// A palette is worth more than the menu it replaces only if finding a command
/// is faster than looking for it, so ranking is deliberately aggressive: a
/// title prefix outranks a word start, which outranks a substring, which
/// outranks a subsequence match. Typing three letters should put the intended
/// command first without requiring the exact wording.
///
/// Keyboard is the primary path — arrows move, Return runs, Escape closes — and
/// the search field keeps focus throughout, so the hands never leave the
/// keyboard.
///
/// ```swift
/// CommandPalette(isPresented: $isPaletteOpen, items: [
///     CommandItem("Toggle Theme", group: "View", shortcut: .primaryShift("L")) { toggleTheme() },
///     CommandItem("Open Recent…", group: "File", keywords: ["history"]) { openRecent() }
/// ])
/// ```
public struct CommandPalette: View {
    @State private var query = TextBuffer.empty
    @State private var highlightedID: String?
    @State private var focusToken = 0
    @State private var recentIDs: [String] = []

    public var isPresented: Binding<Bool>
    public var items: [CommandItem]
    public var placeholder: String
    public var emptyTitle: String
    public var emptyMessage: String
    /// Shows the commands run in this palette above their normal groups when
    /// the query is empty. History is session-scoped and never persisted.
    public var showsRecentCommands = true
    public var recentCommandLimit = 3
    private var customFooter: AnyView?

    static let rowHeight: Float = 40
    static let headerHeight: Float = 24

    public init(isPresented: Binding<Bool>,
                items: [CommandItem],
                configure: (inout Self) -> Void = { _ in }) {
        self.isPresented = isPresented
        self.items = items
        self.placeholder = "Type a command…"
        self.emptyTitle = "No matching commands"
        self.emptyMessage = "Try a different search term."
        configure(&self)
        recentCommandLimit = min(10, max(0, recentCommandLimit))
    }

    /// Replaces the default shortcut-hint footer with caller content.
    public init<Footer: View>(isPresented: Binding<Bool>,
                             items: [CommandItem],
                             configure: (inout Self) -> Void = { _ in },
                             @ViewBuilder footer: () -> Footer) {
        self.init(isPresented: isPresented, items: items, configure: configure)
        customFooter = AnyView(footer())
    }

    public var body: some View {
        ThemeReader { theme in
            SurfaceReader { surface in
                let compact = surface.viewport.width < UIEnvironment.Viewport.compactMaximumWidth
                let touch = surface.input.contains(.touch)
                let itemHeight = touch ? max(Self.rowHeight, surface.minimumControlExtent) : Self.rowHeight
                let headerHeight = touch ? max(Self.headerHeight, 36) : Self.headerHeight
                Modal(isPresented: isPresented) {
                    // The host owns IME geometry: when the soft keyboard appears it
                    // increases `surface.safeArea.bottom`, and the palette must
                    // contract its result viewport instead of being clipped by the
                    // keyboard. Width is unaffected.
                    let availableHeight = max(0, surface.viewport.height - surface.safeArea.bottom)
                    if compact {
                        // A phone loses too much width and height to the desktop
                        // 72pt inset. Use a 16pt window inset and the measured
                        // surface height so the result viewport stays visible.
                        $0.geometry.width = max(240, surface.viewport.width - 16)
                        $0.geometry.height = min(560, max(240, availableHeight - 16))
                        $0.geometry.inset = 8
                        $0.geometry.placement = .center
                    } else {
                        $0.geometry.width = 640
                        $0.geometry.height = min(560, max(240, availableHeight - 144))
                        $0.geometry.inset = 72
                        $0.geometry.placement = .top
                    }
                    $0.geometry.cornerRadius = theme.radius.md
                } content: {
                    Column(alignment: .leading, spacing: 0) {
                        _PresentationWatcher(isPresented: isPresented) { open() }
                        AnyView(searchField)
                        AnyView(Divider())
                        AnyView(results(itemHeight: itemHeight, headerHeight: headerHeight))
                        AnyView(
                            Box {}.frame(height: 1)
                                .background(SemanticColorRef.border)
                                .padding(horizontal: 12)
                        )
                        AnyView(customFooter ?? AnyView(defaultFooter))
                    }
                    .frame(width: .percent(100), height: .percent(100))
                    .debugName("commandPalette.panel")
                }
            }
        }
    }

    // MARK: - Presentation

    private func open() {
        query = .empty
        highlightedID = firstSelectable?.id
        focusToken += 1
    }

    private func close() {
        isPresented.wrappedValue = false
    }

    // MARK: - Search

    private var trimmedQuery: String {
        query.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visible: [CommandItem] { Self.ranked(items, query: trimmedQuery) }

    static func ranked(_ items: [CommandItem], query: String) -> [CommandItem] {
        CommandSearch.ranked(items, query: query)
    }

    private var entries: [CommandEntry] {
        Self.displayEntries(items: visible,
                            recentIDs: trimmedQuery.isEmpty ? recentIDs : [],
                            showsRecent: showsRecentCommands && trimmedQuery.isEmpty,
                            limit: recentCommandLimit,
                            groupsResults: trimmedQuery.isEmpty)
    }

    static func displayEntries(items: [CommandItem], recentIDs: [String],
                               showsRecent: Bool, limit: Int,
                               groupsResults: Bool) -> [CommandEntry] {
        let recent = showsRecent ? recentIDs.compactMap { id in
            items.first { $0.id == id && $0.isEnabled }
        }.prefix(max(0, limit)) : []
        guard !recent.isEmpty else {
            return CommandSearch.entries(items, groupsResults: groupsResults)
        }
        let recentItems = Array(recent)
        let ids = Set(recentItems.map(\.id))
        let remaining = items.filter { !ids.contains($0.id) }
        return [.header("Recent")]
            + recentItems.map(CommandEntry.item)
            + CommandSearch.entries(remaining, groupsResults: groupsResults)
    }

    private var selectable: [CommandItem] {
        entries.compactMap { if case .item(let item) = $0, item.isEnabled { item } else { nil } }
    }
    private var effectiveHighlight: String? {
        selectable.first(where: { $0.id == highlightedID })?.id ?? firstSelectable?.id
    }
    private var firstSelectable: CommandItem? { selectable.first }

    private func move(_ delta: Int, wraps: Bool = true) {
        let candidates = selectable
        guard let index = CommandSearch.destination(count: candidates.count,
            current: candidates.firstIndex { $0.id == effectiveHighlight }, delta: delta, wraps: wraps) else {
            highlightedID = nil; return
        }
        highlightedID = candidates[index].id
    }

    private func run(_ item: CommandItem) {
        guard item.isEnabled else { return }
        recordRecent(item.id)
        close()
        item.action()
    }

    private func recordRecent(_ id: String) {
        guard recentCommandLimit > 0 else { return }
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
        if recentIDs.count > recentCommandLimit {
            recentIDs.removeLast(recentIDs.count - recentCommandLimit)
        }
    }

    private func runHighlighted() {
        guard let item = selectable.first(where: { $0.id == effectiveHighlight }) else { return }
        run(item)
    }

    private var highlightedEntryIndex: Int? {
        guard let highlightedID = effectiveHighlight else { return nil }
        return entries.firstIndex(where: {
            if case .item(let item) = $0 { return item.id == highlightedID }
            return false
        })
    }

    // MARK: - Pieces

    private var searchField: some View {
        Box(direction: .column, alignItems: .stretch) {
        TextField(placeholder, text: $query) { input in
            input.decoration.size = .large
            input.behavior.clearable = true
            input.navigation.focusRequestID = focusToken
            // Arrows, Page keys, Return and Escape belong to the palette, not to
            // caret movement: the query is one line, so nothing is lost.
            input.events.onKeyDown = { event in
                switch event.scancode {
                case Scancode.arrowDown: move(1); return true
                case Scancode.arrowUp: move(-1); return true
                case Scancode.pageDown: move(10, wraps: false); return true
                case Scancode.pageUp: move(-10, wraps: false); return true
                case Scancode.return, Scancode.keypadEnter: runHighlighted(); return true
                case Scancode.escape: close(); return true
                default: return false
                }
            }
            input.events.onChange = { _ in
                highlightedID = firstSelectable?.id
            }
            input.events.onClear = { highlightedID = firstSelectable?.id }
        }
        }
        .frame(width: .percent(100))
        .padding(12)
        .debugName("commandPalette.search")
    }

    @ViewBuilder private func results(itemHeight: Float, headerHeight: Float) -> some View {
        if visible.isEmpty {
            EmptyState(emptyTitle, message: emptyMessage) {
                $0.prominence = .compact
                $0.icon = UIIcons.Action.search
            }
            .padding(horizontal: 6)
            .flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
        } else {
            VirtualStack(entries, id: \.id, rowHeight: { entry, _, _ in
                switch entry {
                case .header: return headerHeight
                case .item: return itemHeight
                }
            },
                                 scrollToIndex: highlightedEntryIndex) { entry in
                switch entry {
                case .header(let title):
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                        .padding(horizontal: 14)
                        .frame(height: headerHeight)
                        .accessibility { $0.role = .staticText }
                case .item(let item):
                    row(item, height: itemHeight)
                }
            }
            .padding(horizontal: 8)
            .debugName("commandPalette.results")
            .frame(width: .percent(100), minHeight: 0)
            .flex(1, shrink: 1, basis: 0)
        }
    }

    private func row(_ item: CommandItem, height: Float) -> some View {
        let isHighlighted = item.id == effectiveHighlight
        return Button(isEnabled: item.isEnabled, isSelected: isHighlighted, action: { run(item) }) {
            Row(alignment: .center, spacing: 10) {
                Icon(item.icon ?? UIIcons.Navigation.arrowRight, size: .medium)
                    .foregroundColor(isHighlighted ? SemanticColorRef.onSurface : .onSurfaceMuted)
                    .accessibilityHidden()
                Text(item.title).font(.label)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).foregroundColor(.onSurfaceMuted)
                }
                Spacer()
                if let shortcut = item.shortcut {
                    shortcutCaps(shortcut)
                }
            }
            .frame(width: .percent(100))
        }
        .buttonStyle(CommandRowStyle())
        .modifier(CommandResultModifier())
        .frame(width: .percent(100)).frame(height: height)
        .onHover { hovered in
            if hovered, item.isEnabled { highlightedID = item.id }
        }
        .accessibility { $0.role = .button; $0.label = item.title; $0.help = item.subtitle }
    }

    private func shortcutCaps(_ shortcut: KeyboardShortcut) -> some View {
        // One quiet shortcut chip reads faster than a row of tiny keycaps and
        // keeps the trailing slot from dominating a 40pt command row.
        Text(shortcut.caps().joined(separator: " "))
            .font(.caption)
            .foregroundColor(.onSurfaceVariant)
            .padding(horizontal: 7, vertical: 4)
            .background(.surfaceVariant)
            .cornerRadius(5)
            .accessibilityHidden()
    }

    private var defaultFooter: some View {
        Row(alignment: .center, spacing: 14) {
            hint("↑↓", "navigate")
            hint("↵", "run")
            hint("esc", "close")
            Spacer()
            Text("\(visible.count) of \(items.count)")
                .font(.caption).foregroundColor(.onSurfaceMuted)
        }
        .padding(horizontal: 14, vertical: 8)
        .debugName("commandPalette.footer")
        .accessibility { $0.role = .group; $0.label = "Keyboard shortcuts" }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        Row(alignment: .center, spacing: 5) {
            KeyCap(key)
            Text(label).font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}


/// Renders the highlighted row as a selection rather than as a button press:
/// the palette's highlight is a cursor, and pressing it does not happen until
/// Return or a click.
private struct CommandRowStyle: ButtonStyle {
    func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        let theme = c.theme
        let fill: Color
        if !c.isEnabled {
            fill = .clear
        } else if c.isSelected {
            fill = theme.colors.accent.multipliedAlpha(0.16)
        } else if c.isPressed {
            fill = theme.colors.stateLayerPressed
        } else if c.isHovered {
            fill = theme.colors.stateLayerHover
        } else {
            fill = .clear
        }
        return Row(alignment: .center) { AnyView(c.label) }
            .frame(width: .percent(100), height: .percent(100))
            .padding(horizontal: 14, vertical: 0)
            .background(fill)
            .cornerRadius(theme.radius.sm)
            .opacity(c.isEnabled ? 1 : 0.45)
            .animation(motion: .fast, value: c.interactionKey)
    }
}

/// Fires once per presentation so the palette can reset its transient state.
///
/// The modal unmounts its content between presentations, so mount-time state
/// is already fresh; the watcher exists to drive the focus token, which must
/// change to be honoured.
private struct _PresentationWatcher: _PrimitiveView {
    let isPresented: Binding<Bool>
    let onPresent: () -> Void

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.width = 0
        layout.height = 0
        return layout
    }

    func _updateNode(_ node: Node) {
        let settled = node.attachments["commandPalette.settled"] as? Bool ?? false
        guard !settled else { return }
        node.attachments["commandPalette.settled"] = true
        if isPresented.wrappedValue { onPresent() }
    }
}

/// Search remains the sole Tab stop; pointer actions still execute each result.
private struct CommandResultModifier: ViewModifier {
    func apply(node: Node) { node.isTabStop = false }
}
