#if canImport(CoreGraphics)
import CoreGraphics
#endif
import GuavaUIRuntime

/// Fixed-height rows materialized only around the viewport. Spacer heights
/// preserve the full scroll extent and keyed rows survive overlapping scrolls.
public struct VirtualList<Data: RandomAccessCollection, ID: Hashable, RowContent: View>: View {
    public let data: Data
    public let id: KeyPath<Data.Element, ID>
    public let rowHeight: Float
    public let rowSpacing: Float
    public let overscan: Int
    public let rowContent: (Data.Element) -> RowContent
    @State private var visibleRange: Range<Int> = 0..<20

    public init(_ data: Data, id: KeyPath<Data.Element, ID>, rowHeight: Float = 30,
                rowSpacing: Float = 0, overscan: Int = 3,
                @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent) {
        self.data = data
        self.id = id
        self.rowHeight = max(1, rowHeight)
        self.rowSpacing = max(0, rowSpacing)
        self.overscan = max(0, overscan)
        self.rowContent = rowContent
    }

    public static func range(count: Int, rowHeight: Float, rowSpacing: Float = 0,
                             offset: Float, viewportHeight: Float, overscan: Int = 3) -> Range<Int> {
        let step = max(1, rowHeight + rowSpacing)
        let lower = max(0, min(count, Int(max(0, offset) / step) - overscan))
        let upper = max(lower, min(count, Int((max(0, offset) + max(0, viewportHeight)) / step) + 1 + overscan))
        return lower..<upper
    }

    public var body: some View {
        let count = data.count
        let lower = min(count, visibleRange.lowerBound)
        let upper = max(lower, min(count, visibleRange.upperBound))
        let step = rowHeight + rowSpacing
        ScrollView(.vertical, scrollbarGutter: .stable, onGeometryChange: { geometry in
            let next = Self.range(count: count, rowHeight: rowHeight, rowSpacing: rowSpacing,
                                  offset: Float(geometry.offset.y), viewportHeight: Float(geometry.viewportSize.height), overscan: overscan)
            if next != visibleRange { visibleRange = next }
        }) {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                if lower > 0 {
                    Box { EmptyView() }.frame(height: Float(lower) * step).flex(0, shrink: 0)
                }
                rows(in: lower..<upper)
                if upper < count {
                    Box { EmptyView() }
                        .frame(height: Float(count - upper) * step - rowSpacing)
                        .flex(0, shrink: 0)
                }
            }
        }
    }
    private func rows(in range: Range<Int>) -> [AnyView] {
        range.map { index in
            let element = data[data.index(data.startIndex, offsetBy: index)]
            return AnyView(Box(direction: .column, alignItems: .stretch) {
                rowContent(element).frame(height: rowHeight).flex(0, shrink: 0)
            }
            .frame(height: rowHeight + (index + 1 < data.count ? rowSpacing : 0))
            .flex(0, shrink: 0)
            .id(element[keyPath: id]))
        }
    }

}
