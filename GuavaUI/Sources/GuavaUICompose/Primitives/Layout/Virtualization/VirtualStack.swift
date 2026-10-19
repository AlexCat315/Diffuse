import GuavaUIRuntime

/// A vertically scrolling stack that constructs only the rows around the
/// viewport. Row identity survives scrolling; keep persistent row data in the
/// model, since fully offscreen rows are unmounted. IDs must be unique.
///
/// Pass a constant `rowHeight` for uniform rows, or a closure for known
/// variable heights. The closure receives the element, the available content
/// width and the inherited text scaler, and returns the complete row height;
/// heights are cached until data, width, spacing or text scale change, and
/// scrolling locates rows in O(log n).
public struct VirtualStack<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    private enum Rows {
        case fixed(Float)
        case variable((Data.Element, Float, TextScaler) -> Float)
    }
    private let data: Data
    private let id: KeyPath<Data.Element, ID>
    private let rows: Rows
    private let spacing: Float
    private let overscan: Int
    private let scrollToIndex: Int?
    private let content: (Data.Element) -> Content

    public init(_ data: Data, id: KeyPath<Data.Element, ID>, rowHeight: Float,
                spacing: Float = 0, overscan: Int = 3, scrollToIndex: Int? = nil,
                @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.init(data, id: id, rows: .fixed(rowHeight), spacing: spacing, overscan: overscan,
                  scrollToIndex: scrollToIndex, content: content)
    }

    public init(_ data: Data, id: KeyPath<Data.Element, ID>,
                rowHeight: @escaping (Data.Element, Float, TextScaler) -> Float,
                spacing: Float = 0, overscan: Int = 3, scrollToIndex: Int? = nil,
                @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.init(data, id: id, rows: .variable(rowHeight), spacing: spacing, overscan: overscan,
                  scrollToIndex: scrollToIndex, content: content)
    }

    private init(_ data: Data, id: KeyPath<Data.Element, ID>, rows: Rows, spacing: Float, overscan: Int,
                 scrollToIndex: Int?, content: @escaping (Data.Element) -> Content) {
        self.data = data; self.id = id; self.rows = rows
        self.spacing = spacing; self.overscan = overscan
        self.scrollToIndex = scrollToIndex; self.content = content
    }

    public var body: some View {
        switch rows {
        case .fixed(let height):
            FixedVirtualStack(data, id: id, rowHeight: height, spacing: spacing, overscan: overscan,
                              scrollToIndex: scrollToIndex, content: content)
        case .variable(let height):
            VariableVirtualStack(data, id: id, rowHeight: height, spacing: spacing, overscan: overscan,
                                 scrollToIndex: scrollToIndex, content: content)
        }
    }
}
