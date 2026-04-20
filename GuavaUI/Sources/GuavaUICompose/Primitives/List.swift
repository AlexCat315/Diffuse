import GuavaUIRuntime

struct _SelectableListRow<Content: View>: View {
    let isSelected: Bool
    let rowHeight: Float
    let rowInsets: EdgeInsets
    let action: () -> Void
    let content: Content

    init(isSelected: Bool,
         rowHeight: Float,
         rowInsets: EdgeInsets,
         action: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.rowHeight = rowHeight
        self.rowInsets = rowInsets
        self.action = action
        self.content = content()
    }

    var body: some View {
        if isSelected {
            button
                .background(Self.selectedFill)
                .cornerRadius(8)
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: action) {
            Box(direction: .row, alignItems: .center, spacing: 8) {
                content
                Spacer(minLength: 0)
            }
            .padding(rowInsets)
            .frame(height: rowHeight)
        }
    }

    private static var selectedFill: Color {
        Color(r: 0.22, g: 0.44, b: 0.78, a: 0.55)
    }
}

public struct List<Data: RandomAccessCollection, ID: Hashable, RowContent: View>: View {
    public let data: Data
    public let id: KeyPath<Data.Element, ID>
    public let selection: Binding<ID?>
    public let rowHeight: Float
    public let rowSpacing: Float
    public let rowInsets: EdgeInsets
    public let onActivate: ((Data.Element) -> Void)?
    public let rowContent: (Data.Element, Bool) -> RowContent

    public init(_ data: Data,
                id: KeyPath<Data.Element, ID>,
                selection: Binding<ID?> = .constant(nil),
                rowHeight: Float = 30,
                rowSpacing: Float = 0,
                rowInsets: EdgeInsets = EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10),
                onActivate: ((Data.Element) -> Void)? = nil,
                @ViewBuilder rowContent: @escaping (Data.Element, Bool) -> RowContent) {
        self.data = data
        self.id = id
        self.selection = selection
        self.rowHeight = rowHeight
        self.rowSpacing = rowSpacing
        self.rowInsets = rowInsets
        self.onActivate = onActivate
        self.rowContent = rowContent
    }

    public var body: some View {
        ScrollView(.vertical) {
            Box(direction: .column, alignItems: .stretch, spacing: rowSpacing) {
                for element in data {
                    _SelectableListRow(isSelected: isSelected(element),
                                       rowHeight: rowHeight,
                                       rowInsets: rowInsets,
                                       action: { activate(element) }) {
                        rowContent(element, isSelected(element))
                    }
                }
            }
        }
    }

    private func isSelected(_ element: Data.Element) -> Bool {
        selection.wrappedValue == element[keyPath: id]
    }

    private func activate(_ element: Data.Element) {
        selection.wrappedValue = element[keyPath: id]
        onActivate?(element)
    }
}

public extension List where Data.Element: Identifiable, ID == Data.Element.ID {
    init(_ data: Data,
         selection: Binding<ID?> = .constant(nil),
         rowHeight: Float = 30,
         rowSpacing: Float = 0,
         rowInsets: EdgeInsets = EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10),
         onActivate: ((Data.Element) -> Void)? = nil,
         @ViewBuilder rowContent: @escaping (Data.Element, Bool) -> RowContent) {
        self.init(data,
                  id: \.id,
                  selection: selection,
                  rowHeight: rowHeight,
                  rowSpacing: rowSpacing,
                  rowInsets: rowInsets,
                  onActivate: onActivate,
                  rowContent: rowContent)
    }
}