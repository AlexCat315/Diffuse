import Foundation
import GuavaUIRuntime

/// Fixed-height rows are created only within the viewport plus overscan. Row
/// identity survives scrolling; persistent row data belongs in the model.
/// Public callers use `VirtualStack`; collections use the offset and refresh seams.
struct FixedVirtualStack<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    private let data: Data
    private let id: KeyPath<Data.Element, ID>
    private let rowHeight: Float
    private let spacing: Float
    private let overscan: Int
    private let scrollToIndex: Int?
    private let onScrollOffsetChange: ((CGPoint) -> Void)?
    private let refresh: RefreshOptions?
    private let content: (Data.Element) -> Content
    @State private var viewport = ScrollViewport(offset: .zero, size: .zero)
    @State private var offset = CGPoint.zero
    @State private var previousTarget: Int?
    @State private var pull: CGFloat = 0
    @State private var refreshArmed = false

    /// `onScrollOffsetChange` lets containers pin content to the live offset
    /// (for example `SectionedList`'s sticky header).
    init(_ data: Data, id: KeyPath<Data.Element, ID>, rowHeight: Float,
         spacing: Float = 0, overscan: Int = 3, scrollToIndex: Int? = nil,
         onScrollOffsetChange: ((CGPoint) -> Void)? = nil,
         refresh: RefreshOptions? = nil,
         @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data; self.id = id
        self.rowHeight = max(1, rowHeight); self.spacing = max(0, spacing)
        self.overscan = max(0, overscan); self.scrollToIndex = scrollToIndex
        self.onScrollOffsetChange = onScrollOffsetChange
        self.refresh = refresh
        self.content = content
    }

    var body: some View {
        let stride = rowHeight + spacing
        let count = data.count
        // The first layout has no viewport yet. Revealing against a zero-height
        // viewport scrolls a row too far and the request is then consumed, so a
        // target that is already visible still starts the stack scrolled past
        // its own top.
        if let target = scrollToIndex, target != previousTarget, viewport.size.height > 0 {
            previousTarget = target
            let top = CGFloat(max(0, min(target, count - 1))) * CGFloat(stride)
            let bottom = top + CGFloat(rowHeight)
            if top < offset.y { offset.y = top }
            else if bottom > offset.y + viewport.size.height {
                offset.y = max(0, bottom - max(CGFloat(rowHeight), viewport.size.height))
            }
        }
        let total = max(0, Float(count) * stride - spacing)
        let refreshInset: Float = refresh?.isRefreshing.wrappedValue == true ? 36 : 0
        let clampedOffset = max(0, min(Float(offset.y), max(0, total - Float(viewport.size.height))))
        let range = Self.visibleRange(count: count, rowStride: stride, offset: clampedOffset,
                                      height: Float(viewport.size.height), overscan: overscan)
        let scroll = ScrollView(.vertical, scrollbarGutter: .stable,
                                scrollOffset: Binding(get: { offset }, set: {
            if offset != $0 {
                offset = $0
                updateRefresh($0)
            }
        }),
                                onViewportChange: { if viewport != $0 { viewport = $0 } },
                                onGeometryChange: { geometry in
                                    onScrollOffsetChange?(geometry.offset)
                                }) {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                if refreshInset > 0 {
                    Box {}.frame(height: refreshInset)
                }
                Box {}.frame(height: Float(range.lowerBound) * stride)
                range.map { row(at: $0) }
                Box {}.frame(height: max(0, total - Float(range.upperBound) * stride + (range.upperBound == count ? spacing : 0)))
                if let refresh, pull > 4 || refresh.isRefreshing.wrappedValue {
                    Box(direction: .row, alignItems: .center, justifyContent: .center) {
                        RefreshIndicator(pull: pull, threshold: CGFloat(refresh.threshold),
                                         isRefreshing: refresh.isRefreshing.wrappedValue)
                    }
                    .frame(width: 140, height: 36)
                    .absolutePosition(left: max(8, (Float(viewport.size.width) - 140) / 2),
                                      top: 8 - Float(pull))
                }
            }
            .frame(height: total + refreshInset, minWidth: 0)
        }
        return scroll
        .modifier(RefreshKeyboardModifier(refresh: refresh))
    }

    private func updateRefresh(_ next: CGPoint) {
        let nextPull = max(0, -next.y)
        if pull != nextPull { pull = nextPull }
        guard let refresh else { return }
        if nextPull <= 1 { refreshArmed = false }
        guard nextPull >= CGFloat(refresh.threshold),
              !refreshArmed,
              !refresh.isRefreshing.wrappedValue else { return }
        refreshArmed = true
        refresh.action()
    }

    private func row(at index: Int) -> AnyView {
        let element = data[data.index(data.startIndex, offsetBy: index)]
        return AnyView(Box(direction: .column, alignItems: .stretch) { content(element) }
            .frame(height: rowHeight + (index < data.count - 1 ? spacing : 0))
            .padding(EdgeInsets(bottom: index < data.count - 1 ? spacing : 0))
            .clipped()
            .id(element[keyPath: id]))
    }

    static func visibleRange(count: Int, rowStride: Float, offset: Float,
                                    height: Float, overscan: Int) -> Range<Int> {
        let stride = max(1, rowStride)
        let first = max(0, min(count, Int(max(0, offset) / stride) - max(0, overscan)))
        let last = min(count, max(first, Int(ceil((max(0, offset) + max(stride, height)) / stride)) + max(0, overscan)))
        return first..<last
    }
}
