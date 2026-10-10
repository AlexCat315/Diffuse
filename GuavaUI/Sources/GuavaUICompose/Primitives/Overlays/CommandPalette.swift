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
/// title prefix outranks a substring, which outranks a word start, which
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
    @State private var scrollOffset = CGPoint.zero
    @State private var viewportHeight: Float = 0
    @State private var focusToken = 0

    public var isPresented: Binding<Bool>
    public var items: [CommandItem]
    public var placeholder: String
    public var emptyTitle: String
    public var emptyMessage: String

    static let rowHeight: Float = 36
    static let headerHeight: Float = 28

    public init(isPresented: Binding<Bool>,
                items: [CommandItem],
                configure: (inout Self) -> Void = { _ in }) {
        self.isPresented = isPresented
        self.items = items
        self.placeholder = "Type a command…"
        self.emptyTitle = "No matching commands"
        self.emptyMessage = "Try a different search term."
        configure(&self)
    }

    public var body: some View {
        Modal(isPresented: isPresented) {
            $0.geometry.width = 640
            $0.geometry.height = 440
            $0.geometry.inset = 72
            $0.geometry.cornerRadius = 10
            $0.geometry.placement = .top
        } content: {
            Column(alignment: .leading, spacing: 0) {
                _PresentationWatcher(isPresented: isPresented) { open() }
                AnyView(searchField)
                AnyView(Divider())
                AnyView(results)
                AnyView(footer)
            }
        }
    }

    // MARK: - Presentation

    private func open() {
        query = .empty
        scrollOffset = .zero
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

    /// Ranks `items` against `query`.
    ///
    /// Split out from the view so the scoring table is exercised directly: a
    /// palette that only looks right in the gallery is a palette nobody can
    /// regression-test.
    static func ranked(_ items: [CommandItem], query: String) -> [CommandItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return items }
        var scored: [(score: Int, order: Int, item: CommandItem)] = []
        for (order, item) in items.enumerated() {
            guard let score = score(item: item, terms: terms) else { continue }
            scored.append((score, order, item))
        }
        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.order < rhs.order : lhs.score > rhs.score
        }
        return scored.map(\.item)
    }

    private static func score(item: CommandItem, terms: [String]) -> Int? {
        let title = item.title.lowercased()
        let haystack = ([item.title, item.subtitle, item.group] + item.keywords)
            .joined(separator: " ").lowercased()
        var total = 0
        for term in terms {
            let best: Int
            if title.hasPrefix(term) {
                best = 1000
            } else if title.contains(term) {
                best = 700
            } else if title.split(whereSeparator: \.isWhitespace).contains(where: { $0.hasPrefix(term) }) {
                best = 520
            } else if let fuzzy = subsequenceScore(title, term) {
                best = 200 + fuzzy
            } else if item.keywords.contains(where: { $0.lowercased().contains(term) }) {
                best = 300
            } else if haystack.contains(term) {
                best = 120
            } else {
                return nil
            }
            total += best
        }
        // Disabled commands stay visible — hiding them makes the palette feel
        // broken when the user knows the command exists — but always sort last.
        return item.isEnabled ? total : total - 10_000
    }

    /// Score for a non-contiguous match.
    ///
    /// The penalty is proportional to how many characters were *skipped*, not
    /// to how many gaps there were: with a per-gap penalty "gt" ties "Git
    /// Toggle" and "Generate Textures" at one gap each, even though the second
    /// jumps across eight characters to make the match.
    private static func subsequenceScore(_ text: String, _ term: String) -> Int? {
        var cursor = text.startIndex
        var skipped = 0
        var previous: String.Index?
        for character in term {
            guard let found = text[cursor...].firstIndex(of: character) else { return nil }
            if let previous { skipped += text.distance(from: previous, to: found) - 1 }
            previous = found
            cursor = text.index(after: found)
        }
        return max(20, 90 - skipped * 5)
    }

    // MARK: - Rows

    private enum Entry {
        case header(String)
        case item(CommandItem)
    }

    private var entries: [Entry] {
        let visible = visible
        let groups = Set(visible.map(\.group))
        guard groups.count > 1 else { return visible.map { .item($0) } }
        var out: [Entry] = []
        var current = ""
        for item in visible where item.group != current || out.isEmpty {
            current = item.group
            out.append(.header(current))
            out.append(contentsOf: visible.filter { $0.group == current }.map { .item($0) })
        }
        return out
    }

    private var selectable: [CommandItem] { visible.filter(\.isEnabled) }
    private var firstSelectable: CommandItem? { selectable.first }

    private func move(_ delta: Int) {
        let candidates = selectable
        guard !candidates.isEmpty else { highlightedID = nil; return }
        let currentIndex = candidates.firstIndex { $0.id == highlightedID }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = (currentIndex + delta + candidates.count) % candidates.count
        } else {
            nextIndex = delta > 0 ? 0 : candidates.count - 1
        }
        highlightedID = candidates[nextIndex].id
        scrollHighlightIntoView()
    }

    private func run(_ item: CommandItem) {
        guard item.isEnabled else { return }
        close()
        item.action()
    }

    private func runHighlighted() {
        guard let item = selectable.first(where: { $0.id == highlightedID }) else { return }
        run(item)
    }

    /// Keeps the highlighted row visible using known row heights rather than a
    /// measured geometry pass: the list is uniform by design, so the arithmetic
    /// is exact and never lags a frame behind the selection.
    private func scrollHighlightIntoView() {
        guard let highlightedID, viewportHeight > 1 else { return }
        var y: Float = 0
        for entry in entries {
            switch entry {
            case .header:
                y += Self.headerHeight
            case .item(let item):
                if item.id == highlightedID { reveal(y); return }
                y += Self.rowHeight
            }
        }
    }

    private func reveal(_ y: Float) {
        let viewport = CGFloat(viewportHeight)
        let rowHeight = CGFloat(Self.rowHeight)
        var offset = scrollOffset.y
        if CGFloat(y) < offset {
            offset = CGFloat(y)
        } else if CGFloat(y) + rowHeight > offset + viewport {
            offset = CGFloat(y) + rowHeight - viewport
        }
        let contentHeight = CGFloat(entries.reduce(Float(0)) { total, entry in
            switch entry {
            case .header: total + Self.headerHeight
            case .item: total + Self.rowHeight
            }
        })
        offset = max(0, min(offset, max(0, contentHeight - viewport)))
        if abs(offset - scrollOffset.y) > 0.5 { scrollOffset.y = offset }
    }

    // MARK: - Pieces

    private var searchField: some View {
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
                case Scancode.pageDown: move(10); return true
                case Scancode.pageUp: move(-10); return true
                case Scancode.return, Scancode.keypadEnter: runHighlighted(); return true
                case Scancode.escape: close(); return true
                default: return false
                }
            }
            input.events.onChange = { _ in
                highlightedID = firstSelectable?.id
                scrollOffset = .zero
            }
            input.events.onClear = { highlightedID = firstSelectable?.id }
        }
        .padding(12)
        .debugName("commandPalette.search")
    }

    @ViewBuilder private var results: some View {
        if visible.isEmpty {
            EmptyState(emptyTitle, message: emptyMessage) {
                $0.prominence = .compact
                $0.icon = UIIcons.Action.search
            }
            .flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
        } else {
            ScrollView(.vertical, scrollOffset: $scrollOffset, onGeometryChange: { geometry in
                let height = Float(geometry.viewportSize.height)
                if abs(height - viewportHeight) > 0.5 { viewportHeight = height }
            }) {
                Column(alignment: .leading, spacing: 0) {
                    for entry in entries {
                        switch entry {
                        case .header(let title):
                            AnyView(Text(title.uppercased())
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)
                                .padding(horizontal: 14)
                                .frame(height: Self.headerHeight)
                                .accessibility { $0.role = .staticText })
                        case .item(let item):
                            AnyView(row(item))
                        }
                    }
                }
            }
            .flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
        }
    }

    private func row(_ item: CommandItem) -> some View {
        let isHighlighted = item.id == highlightedID
        return Button(isEnabled: item.isEnabled, isSelected: isHighlighted, action: { run(item) }) {
            Row(alignment: .center, spacing: 10) {
                Icon(item.icon ?? UIIcons.Navigation.arrowRight, size: 16)
                    .foregroundColor(isHighlighted ? SemanticColorRef.onSurface : .onSurfaceMuted)
                    .accessibilityHidden()
                Text(item.title).font(.label)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).foregroundColor(.onSurfaceMuted)
                }
                Spacer()
                if let shortcut = item.shortcut {
                    KeyCap(shortcut).accessibilityHidden()
                }
            }
        }
        .buttonStyle(CommandRowStyle())
        .frame(height: Self.rowHeight)
        .onHover { hovered in
            if hovered, item.isEnabled { highlightedID = item.id }
        }
        .accessibility { $0.role = .button; $0.label = item.title; $0.help = item.subtitle }
    }

    private var footer: some View {
        Row(alignment: .center, spacing: 14) {
            hint("↑↓", "navigate")
            hint("↵", "run")
            hint("esc", "close")
            Spacer()
            Text("\(visible.count) of \(items.count)")
                .font(.caption).foregroundColor(.onSurfaceMuted)
        }
        .padding(horizontal: 14, vertical: 8)
        .border(SemanticColorRef.border, width: 1)
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
            .padding(horizontal: 14, vertical: 0)
            .background(fill)
            .border(c.isSelected ? theme.colors.accent.multipliedAlpha(0.5) : .clear, width: 1)
            .cornerRadius(theme.radius.sm)
            .opacity(c.isEnabled ? 1 : 0.45)
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
