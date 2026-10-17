import GuavaUIRuntime

/// One flat section in a `SectionedList`. Headers and footers are optional;
/// sections are not sticky yet.
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
public struct SectionedList<SectionID: Hashable, Item: Identifiable, RowContent: View>: View {
    public let sections: [ListSection<SectionID, Item>]
    public let selection: Binding<Item.ID?>
    public let rowHeight: Float
    public let rowSpacing: Float
    public let onActivate: ((Item) -> Void)?
    public let rowContent: (Item, Bool) -> RowContent

    @State private var cursor: Item.ID?

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
                onActivate: ((Item) -> Void)? = nil,
                @ViewBuilder rowContent: @escaping (Item, Bool) -> RowContent) {
        self.sections = sections
        self.selection = selection
        self.rowHeight = max(1, rowHeight)
        self.rowSpacing = max(0, rowSpacing)
        self.onActivate = onActivate
        self.rowContent = rowContent
    }

    public var body: some View {
        SurfaceReader { surface in
            TextScalerReader { scaler in
                let effectiveHeight = max(scaler.scale(rowHeight),
                                          surface.input.contains(.touch) ? surface.minimumControlExtent : 0)
                let entries = makeEntries()
                SelectionKeyHost(onKey: handleKey) {
                    VirtualStack(entries, id: \.id, rowHeight: effectiveHeight,
                                 spacing: scaler.scale(rowSpacing),
                                 scrollToIndex: cursorIndex(in: entries)) { entry in
                        switch entry {
                        case .header(let id, let title):
                            Text(title.uppercased())
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)
                                .padding(horizontal: 10)
                                .frame(height: effectiveHeight)
                                .accessibility { $0.role = .staticText; $0.label = title }
                                .id(id)
                        case .footer(let id, let text):
                            Text(text)
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)
                                .padding(horizontal: 10)
                                .frame(height: effectiveHeight)
                                .accessibility { $0.role = .staticText; $0.label = text }
                                .id(id)
                        case .item(let item):
                            let selected = selection.wrappedValue == item.id
                            _ListRowHost(isSelected: selected, rowHeight: effectiveHeight,
                                         onActivate: { activate(item) },
                                         onTap: { _ in tap(item) },
                                         content: AnyView(rowContent(item, selected)))
                                .id(item.id)
                        }
                    }
                    .frame(width: .percent(100), minHeight: 0)
                    .flex(1, shrink: 1, basis: 0)
                }
            }
        }
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
