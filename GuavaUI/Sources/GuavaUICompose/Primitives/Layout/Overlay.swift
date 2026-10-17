import Foundation

/// Places overlay content on top of the base view without changing the base's
/// measured size. This is the layout behind `.overlay(alignment:content:)`.
public struct OverlayLayout: Layout {
    public var alignment: Alignment

    public init(alignment: Alignment = .center) {
        self.alignment = alignment
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                              subviews: [LayoutSubview]) {
        guard !subviews.isEmpty else { return }
        let boundsProposal = ProposedViewSize(width: bounds.width, height: bounds.height)
        subviews[0].place(at: bounds.origin, proposal: boundsProposal)
        guard subviews.count > 1 else { return }

        let overlay = subviews[1]
        let size = overlay.sizeThatFits(boundsProposal)
        let parts = alignmentComponents
        let rtl = overlay.layoutDirection == .rtl
        let x = bounds.minX + horizontalOffset(parts.horizontal,
                                              available: bounds.width - size.width, rtl: rtl)
        let y = bounds.minY + verticalOffset(parts.vertical,
                                            available: bounds.height - size.height)
        overlay.place(at: CGPoint(x: x, y: y),
                      proposal: ProposedViewSize(width: size.width, height: size.height))
    }

    private var alignmentComponents: (horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        switch alignment {
        case .topLeading: return (.leading, .top)
        case .top: return (.center, .top)
        case .topTrailing: return (.trailing, .top)
        case .leading: return (.leading, .center)
        case .center: return (.center, .center)
        case .trailing: return (.trailing, .center)
        case .bottomLeading: return (.leading, .bottom)
        case .bottom: return (.center, .bottom)
        case .bottomTrailing: return (.trailing, .bottom)
        }
    }

    private func horizontalOffset(_ alignment: HorizontalAlignment,
                                  available: CGFloat, rtl: Bool) -> CGFloat {
        switch alignment {
        case .leading: return rtl ? available : 0
        case .center: return available / 2
        case .trailing: return rtl ? 0 : available
        }
    }

    private func verticalOffset(_ alignment: VerticalAlignment, available: CGFloat) -> CGFloat {
        switch alignment {
        case .top: return 0
        case .center: return available / 2
        case .bottom: return available
        }
    }
}

/// Base view plus one overlay child. The base owns the measured size; the
/// overlay is aligned inside those bounds and may paint outside them if larger.
public struct Overlay<Base: View, Content: View>: View {
    public let base: Base
    public let overlay: Content
    public let alignment: Alignment

    public init(base: Base, overlay: Content, alignment: Alignment) {
        self.base = base
        self.overlay = overlay
        self.alignment = alignment
    }

    public var body: some View {
        OverlayLayout(alignment: alignment) {
            base
            overlay
        }
    }
}

public extension View {
    /// Attach content to the bounds of this view without changing its measured
    /// size. Prefer this over placing a sibling `Text`/`Badge` with padding in a
    /// surrounding `ZStack`: the overlay is laid out against the base bounds, so
    /// font scaling and clipping cannot drift it away from the base.
    func overlay<Content: View>(alignment: Alignment = .center,
                                @ViewBuilder content: () -> Content) -> some View {
        Overlay(base: self, overlay: content(), alignment: alignment)
    }
}
