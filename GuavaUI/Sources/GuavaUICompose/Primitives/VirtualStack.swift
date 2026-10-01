import Foundation
import GuavaUIRuntime

/// Fixed-height rows are created only within the viewport plus overscan. Row
/// identity survives scrolling; persistent row data belongs in the model.
public struct VirtualStack<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    private let data: Data
    private let id: KeyPath<Data.Element, ID>
    private let rowHeight: Float
    private let spacing: Float
    private let overscan: Int
    private let scrollToIndex: Int?
    private let content: (Data.Element) -> Content
    @State private var viewport = ScrollViewport(offset: .zero, size: .zero)
    @State private var offset = CGPoint.zero
    @State private var previousTarget: Int?

    public init(_ data: Data, id: KeyPath<Data.Element, ID>, rowHeight: Float,
                spacing: Float = 0, overscan: Int = 3, scrollToIndex: Int? = nil,
                @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data; self.id = id
        self.rowHeight = max(1, rowHeight); self.spacing = max(0, spacing)
        self.overscan = max(0, overscan); self.scrollToIndex = scrollToIndex
        self.content = content
    }

    public var body: some View {
        let stride = rowHeight + spacing
        let count = data.count
        if let target = scrollToIndex, target != previousTarget {
            previousTarget = target
            let top = CGFloat(max(0, min(target, count - 1))) * CGFloat(stride)
            let bottom = top + CGFloat(rowHeight)
            if top < offset.y { offset.y = top }
            else if bottom > offset.y + viewport.size.height {
                offset.y = max(0, bottom - max(CGFloat(rowHeight), viewport.size.height))
            }
        }
        let total = max(0, Float(count) * stride - spacing)
        let clampedOffset = max(0, min(Float(offset.y), max(0, total - Float(viewport.size.height))))
        let range = Self.visibleRange(count: count, rowStride: stride, offset: clampedOffset,
                                      height: Float(viewport.size.height), overscan: overscan)
        return ScrollView(.vertical, scrollbarGutter: .stable,
                          scrollOffset: Binding(get: { offset }, set: { if offset != $0 { offset = $0 } }),
                          onViewportChange: { if viewport != $0 { viewport = $0 } }) {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                Box {}.frame(height: Float(range.lowerBound) * stride)
                range.map { row(at: $0) }
                Box {}.frame(height: max(0, total - Float(range.upperBound) * stride + (range.upperBound == count ? spacing : 0)))
            }
            .frame(height: total, minWidth: 0)
        }
    }

    private func row(at index: Int) -> AnyView {
        let element = data[data.index(data.startIndex, offsetBy: index)]
        return AnyView(Box(direction: .column, alignItems: .stretch) { content(element) }
            .frame(height: rowHeight + (index < data.count - 1 ? spacing : 0))
            .padding(EdgeInsets(bottom: index < data.count - 1 ? spacing : 0))
            .clipped()
            .id(element[keyPath: id]))
    }

    public static func visibleRange(count: Int, rowStride: Float, offset: Float,
                                    height: Float, overscan: Int) -> Range<Int> {
        let stride = max(1, rowStride)
        let first = max(0, min(count, Int(max(0, offset) / stride) - max(0, overscan)))
        let last = min(count, max(first, Int(ceil((max(0, offset) + max(stride, height)) / stride)) + max(0, overscan)))
        return first..<last
    }
}
