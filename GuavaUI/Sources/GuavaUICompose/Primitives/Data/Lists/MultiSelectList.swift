import Foundation
import GuavaUIRuntime

/// Vertical list with stable multi-selection. A plain click selects one row,
/// Shift-click selects the range from the last anchor, and Cmd/Ctrl-click
/// toggles one row. Keyboard arrows move the cursor; Shift+Arrow extends from
/// the anchor; Cmd/Ctrl+A selects everything.
public struct MultiSelectList<Data: RandomAccessCollection, ID: Hashable, RowContent: View>: View {
    public let data: Data
    public let id: KeyPath<Data.Element, ID>
    public let selection: Binding<Set<ID>>
    public let rowHeight: Float
    public let rowSpacing: Float
    public let onActivate: ((Data.Element) -> Void)?
    public let rowContent: (Data.Element, Bool) -> RowContent

    @State private var anchor: ID?
    @State private var cursor: ID?

    public init(_ data: Data,
                id: KeyPath<Data.Element, ID>,
                selection: Binding<Set<ID>> = .constant([]),
                rowHeight: Float = 30,
                rowSpacing: Float = 0,
                onActivate: ((Data.Element) -> Void)? = nil,
                @ViewBuilder rowContent: @escaping (Data.Element, Bool) -> RowContent) {
        self.data = data
        self.id = id
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
                SelectionKeyHost(onKey: handleKey) {
                    VirtualStack(data, id: id, rowHeight: effectiveHeight,
                                 spacing: scaler.scale(rowSpacing),
                                 scrollToIndex: cursor.flatMap(index(of:))) { element in
                        let selected = selection.wrappedValue.contains(element[keyPath: id])
                        _ListRowHost(isSelected: selected, rowHeight: effectiveHeight,
                                     onActivate: { activate(element) },
                                     onTap: { modifiers in tap(element, modifiers) },
                                     content: AnyView(rowContent(element, selected)))
                    }
                    .flex().frame(minWidth: 0, minHeight: 0)
                }
            }
        }
    }

    private func index(of target: ID) -> Int? {
        data.firstIndex { $0[keyPath: id] == target }
            .map { data.distance(from: data.startIndex, to: $0) }
    }

    private func element(at index: Int) -> Data.Element {
        data[data.index(data.startIndex, offsetBy: index)]
    }

    private func tap(_ element: Data.Element, _ modifiers: KeyModifiers) {
        let value = element[keyPath: id]
        if modifiers.contains(.shift), let anchor, let start = index(of: anchor), let end = index(of: value) {
            selection.wrappedValue = Set(data.dropFirst(min(start, end)).prefix(max(start, end) - min(start, end) + 1).map { $0[keyPath: id] })
        } else if modifiers.contains(.gui) || modifiers.contains(.ctrl) {
            var next = selection.wrappedValue
            if next.contains(value) { next.remove(value) } else { next.insert(value) }
            selection.wrappedValue = next
        } else {
            selection.wrappedValue = [value]
        }
        anchor = value
        cursor = value
    }

    private func activate(_ element: Data.Element) {
        selection.wrappedValue = [element[keyPath: id]]
        anchor = element[keyPath: id]
        cursor = element[keyPath: id]
        onActivate?(element)
    }

    private func handleKey(_ event: KeyEvent) -> Bool {
        guard !data.isEmpty else { return false }
        let current = cursor.flatMap(index(of:))
            ?? selection.wrappedValue.first.flatMap(index(of:))
        if (event.modifiers.contains(.gui) || event.modifiers.contains(.ctrl)), event.scancode == Scancode.a {
            selection.wrappedValue = Set(data.map { $0[keyPath: id] })
            anchor = data.first.map { $0[keyPath: id] }
            cursor = data.last.map { $0[keyPath: id] }
            return true
        }
        if event.scancode == Scancode.space, let current {
            let value = element(at: current)[keyPath: id]
            var next = selection.wrappedValue
            if next.contains(value) { next.remove(value) } else { next.insert(value) }
            selection.wrappedValue = next
            anchor = value
            cursor = value
            return true
        }
        let next: Int
        switch event.scancode {
        case Scancode.arrowDown: next = min(data.count - 1, (current ?? -1) + 1)
        case Scancode.arrowUp: next = max(0, (current ?? data.count) - 1)
        case Scancode.home: next = 0
        case Scancode.end: next = data.count - 1
        case Scancode.return, Scancode.keypadEnter:
            guard let current else { return false }
            activate(element(at: current))
            return true
        default:
            return false
        }
        let value = element(at: next)[keyPath: id]
        if event.modifiers.contains(.shift), let anchor, let start = index(of: anchor), let end = index(of: value) {
            selection.wrappedValue = Set(data.dropFirst(min(start, end)).prefix(max(start, end) - min(start, end) + 1).map { $0[keyPath: id] })
        } else {
            selection.wrappedValue = [value]
            anchor = value
        }
        cursor = value
        return true
    }
}

public extension MultiSelectList where Data.Element: Identifiable, ID == Data.Element.ID {
    init(_ data: Data,
         selection: Binding<Set<ID>> = .constant([]),
         rowHeight: Float = 30,
         rowSpacing: Float = 0,
         onActivate: ((Data.Element) -> Void)? = nil,
         @ViewBuilder rowContent: @escaping (Data.Element, Bool) -> RowContent) {
        self.init(data, id: \.id, selection: selection, rowHeight: rowHeight,
                  rowSpacing: rowSpacing, onActivate: onActivate, rowContent: rowContent)
    }
}
