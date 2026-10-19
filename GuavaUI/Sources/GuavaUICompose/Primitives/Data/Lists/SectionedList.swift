import GuavaUIRuntime

/// One flat section in a `SectionedList`. Headers and footers are optional;
/// headers can be pinned while their section scrolls (see `stickyHeaders`).
public struct ListSection<SectionID: Hashable, Item> {
    public let id: SectionID
    public var title: String?
    public var footer: String?
    public var items: [Item]

    public init(_ id: SectionID, title: String? = nil, footer: String? = nil, items: [Item]) {
        self.id = id
        self.title = title
        self.footer = footer
        self.items = items
    }
}

/// Vertically virtualized list with flat section headers/footers. Selection
/// and keyboard navigation only visit item rows; headers are non-focusable.
/// With `stickyHeaders`, the active section title stays pinned to the top of
/// the viewport and is pushed out by the next section header.
public struct SectionedList<SectionID: Hashable, Item: Identifiable, RowContent: View>: View {
    public let sections: [ListSection<SectionID, Item>]
    public let selection: Binding<Item.ID?>
    public let rowHeight: Float
    public let rowSpacing: Float
    public let stickyHeaders: Bool
    public let stickyHeaderBackground: SemanticColorRef
    public let onActivate: ((Item) -> Void)?
    public let rowContent: (Item, Bool) -> RowContent

    @State private var cursor: Item.ID?
    @State private var scrollOffset: Float = 0

    private struct StickyHeader {
        let title: String
        let y: Float
    }

    private enum EntryID: Hashable {
        case header(SectionID)
        case footer(SectionID)
        case item(Item.ID)
    }

    private enum Entry {
        case header(SectionID, String)
        case footer(SectionID, String)
        case item(Item)

        var id: EntryID {
            switch self {
            case .header(let id, _): return .header(id)
            case .footer(let id, _): return .footer(id)
            case .item(let item): return .item(item.id)
            }
        }
    }

    public init(_ sections: [ListSection<SectionID, Item>],
                selection: Binding<Item.ID?> = .constant(nil),
                rowHeight: Float = 30,
                rowSpacing: Float = 0,
                stickyHeaders: Bool = false,
                stickyHeaderBackground: SemanticColorRef = .surfaceRaised,
                onActivate: ((Item) -> Void)? = nil,
                @ViewBuilder rowContent: @escaping (Item, Bool) -> RowContent) {
        self.sections = sections
        self.selection = selection
        self.rowHeight = max(1, rowHeight)
        self.rowSpacing = max(0, rowSpacing)
        self.stickyHeaders = stickyHeaders
        self.stickyHeaderBackground = stickyHeaderBackground
        self.onActivate = onActivate
        self.rowContent = rowContent
    }

    public var body: some View {
        ContainerSizeReader { size in
            SurfaceReader { surface in
                TextScalerReader { scaler in
                    let effectiveHeight = max(scaler.scale(rowHeight),
                                              surface.input.contains(.touch) ? surface.minimumControlExtent : 0)
                    let spacing = scaler.scale(rowSpacing)
                    let entries = makeEntries()
                    let sticky = stickyHeader(in: entries, offset: scrollOffset,
                                              rowHeight: effectiveHeight, spacing: spacing)
                    SelectionKeyHost(onKey: handleKey) {
                        FixedVirtualStack(entries, id: \.id, rowHeight: effectiveHeight,
                                     spacing: spacing,
                                     scrollToIndex: cursorIndex(in: entries),
                                     onScrollOffsetChange: { value in
                                         let y = Float(value.y)
                                         if abs(y - scrollOffset) > 0.25 { scrollOffset = y }
                                     }) { entry in
                            entryView(entry, height: effectiveHeight)
                        }
                        .frame(width: .percent(100), minHeight: 0)
                        .flex(1, shrink: 1, basis: 0)
                        .overlay(alignment: .top) {
                            if let sticky {
                                stickyHeaderView(sticky, height: effectiveHeight,
                                                 width: Float(size.width), lane: ScrollView<EmptyView>.stableGutterWidth(on: surface))
                            }
                        }
                        // The pushed-up header must not paint over the content
                        // above the list while the next section takes its place.
                        .clipped()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: Entry, height: Float) -> some View {
        switch entry {
        case .header(let id, let title):
            Text(title)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .padding(horizontal: 10)
                .frame(height: height)
                .accessibility { $0.role = .staticText; $0.label = title }
                .id(id)
        case .footer(let id, let text):
            Text(text)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .padding(horizontal: 10)
                .frame(height: height)
                .accessibility { $0.role = .staticText; $0.label = text }
                .id(id)
        case .item(let item):
            let selected = selection.wrappedValue == item.id
            _ListRowHost(isSelected: selected, rowHeight: height,
                         onActivate: { activate(item) },
                         onTap: { _ in tap(item) },
                         content: AnyView(rowContent(item, selected)))
                .id(item.id)
        }
    }

    private func stickyHeaderView(_ header: StickyHeader, height: Float, width: Float, lane: Float) -> some View {
        // The overlay is measured at its intrinsic width, so a percentage frame
        // would only cover the label. Use the container query width and anchor
        // the opaque band physically at the leading edge, leaving the stable
        // scrollbar lane clear when the bar is visible.
        Box {
            Box(direction: .row, alignItems: .center, spacing: 0) {
                Text(header.title)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .padding(horizontal: 10)
                    .accessibility { $0.role = .staticText; $0.label = header.title }
                Spacer(minLength: 0)
            }
            .frame(width: .points(max(1, width - lane)),
                   height: .points(height))
            .background(stickyHeaderBackground)
            // A hairline separates the pinned title from the partially
            // scrolled row underneath without changing the row height.
            .overlay(alignment: .bottom) { Divider() }
            .debugName("sectioned-list-sticky-band")
            .absolutePosition(left: 0, top: 0)
        }
        .frame(width: .points(max(1, width)), height: .points(height))
        // The inline header row already carries the semantic value. The pinned
        // copy is visual only, so it cannot duplicate the section title.
        .accessibilityHidden()
        .allowsHitTesting(false)
        .debugName("sectioned-list-sticky-header")
        .offset(y: header.y)
    }

    /// Resolve the header that should stay pinned at the current offset. It
    /// only appears once its inline row has scrolled past the top; the next
    /// header then pushes it up instead of letting the two overlap.
    private func stickyHeader(in entries: [Entry], offset: Float, rowHeight: Float,
                              spacing: Float) -> StickyHeader? {
        guard stickyHeaders, !entries.isEmpty else { return nil }
        let stride = max(1, rowHeight + spacing)
        var active: (index: Int, title: String)?
        var nextTop: Float?
        for (index, entry) in entries.enumerated() {
            guard case .header(_, let title) = entry else { continue }
            let top = Float(index) * stride
            if top <= offset + 0.5 {
                active = (index, title)
            } else {
                nextTop = top
                break
            }
        }
        guard let active else { return nil }
        let naturalTop = Float(active.index) * stride
        guard offset > naturalTop + 0.5 else { return nil }
        let y: Float
        if let nextTop {
            y = min(0, nextTop - offset - rowHeight)
        } else {
            y = 0
        }
        return StickyHeader(title: active.title, y: y)
    }

    private func makeEntries() -> [Entry] {
        sections.flatMap { section -> [Entry] in
            var result: [Entry] = []
            if let title = section.title, !title.isEmpty { result.append(.header(section.id, title)) }
            result.append(contentsOf: section.items.map(Entry.item))
            if let footer = section.footer, !footer.isEmpty { result.append(.footer(section.id, footer)) }
            return result
        }
    }

    private func itemEntries(_ entries: [Entry]) -> [(index: Int, item: Item)] {
        entries.enumerated().compactMap { index, entry in
            if case .item(let item) = entry { return (index, item) }
            return nil
        }
    }

    private func cursorIndex(in entries: [Entry]) -> Int? {
        guard let cursor else { return nil }
        return entries.firstIndex { if case .item(let item) = $0 { return item.id == cursor }; return false }
    }

    private func tap(_ item: Item) {
        cursor = item.id
        selection.wrappedValue = item.id
    }

    private func activate(_ item: Item) {
        tap(item)
        onActivate?(item)
    }

    private func handleKey(_ event: KeyEvent) -> Bool {
        let entries = makeEntries()
        let items = itemEntries(entries)
        guard !items.isEmpty else { return false }
        let current = cursor.flatMap { id in items.firstIndex { $0.item.id == id } }
            ?? selection.wrappedValue.flatMap { id in items.firstIndex { $0.item.id == id } }
        if event.scancode == Scancode.return || event.scancode == Scancode.keypadEnter {
            guard let current else { return false }
            activate(items[current].item)
            return true
        }
        let next: Int
        switch event.scancode {
        case Scancode.arrowDown: next = min(items.count - 1, (current ?? -1) + 1)
        case Scancode.arrowUp: next = max(0, (current ?? items.count) - 1)
        case Scancode.home: next = 0
        case Scancode.end: next = items.count - 1
        default: return false
        }
        cursor = items[next].item.id
        selection.wrappedValue = items[next].item.id
        return true
    }
}
