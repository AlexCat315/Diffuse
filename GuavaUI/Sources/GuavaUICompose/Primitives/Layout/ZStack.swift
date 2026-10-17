import Foundation

/// Layered container. Children are measured against the available proposal and
/// placed on top of each other in declaration order: the last child paints on
/// top and receives pointer input before earlier children.
///
/// The stack itself measures to its largest child. It does not clip; overflow
/// remains painted and hit-testable unless the caller applies `.clipped()`.
public struct ZStackLayout: Layout {
    public var alignment: Alignment

    public init(alignment: Alignment = .center) {
        self.alignment = alignment
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(proposal)
            width = max(width, size.width)
            height = max(height, size.height)
        }
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                              subviews: [LayoutSubview]) {
        let childProposal = ProposedViewSize(width: bounds.width, height: bounds.height)
        let parts = alignmentComponents
        for subview in subviews {
            let size = subview.sizeThatFits(childProposal)
            let rtl = subview.layoutDirection == .rtl
            let x = bounds.minX + horizontalOffset(parts.horizontal,
                                                  available: bounds.width - size.width, rtl: rtl)
            let y = bounds.minY + verticalOffset(parts.vertical,
                                                available: bounds.height - size.height)
            subview.place(at: CGPoint(x: x, y: y),
                          proposal: ProposedViewSize(width: size.width, height: size.height))
        }
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

/// Layer children in declaration order. The last child is painted and hit
/// first; earlier children remain mounted and keep their state.
public struct ZStack<Content: View>: View {
    public var alignment: Alignment
    public let content: Content

    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    public var body: some View {
        ZStackLayout(alignment: alignment) { content }
    }
}
