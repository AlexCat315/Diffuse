import Foundation
import GuavaUIRuntime

/// Detail card shown while the pointer rests on a trigger, without a click.
///
/// Two details separate a hover card from a tooltip: it survives the pointer
/// moving onto the card itself, and it waits before appearing. The waits are
/// asymmetric — a long open delay so passing the pointer across a dense list
/// does not flash cards, and a short close delay so the brief gap between
/// trigger and card does not dismiss it.
///
/// Hover cards are a pointer affordance and must not be the only path to the
/// information they carry; pair one with a click target or an inline detail
/// view so keyboard and touch users reach the same content.
///
/// ```swift
/// HoverCard(width: 320, label: { Text("@ada").font(.label) }) {
///     Column(alignment: .leading, spacing: 6) {
///         Text("Ada Lovelace").font(.bodyStrong)
///         Text("Analytical Engine · since 1843").font(.caption).foregroundColor(.onSurfaceMuted)
///     }
/// }
/// ```
public struct HoverCard<Label: View, Content: View>: View {
    @State private var isPresented = false
    @State private var triggerHovered = false
    @State private var cardHovered = false

    /// Seconds the pointer must rest on the trigger before the card opens.
    public var openDelay: Double
    /// Grace period after the pointer leaves before the card closes.
    public var closeDelay: Double
    public var width: Float?
    public var isEnabled: Bool
    public let label: Label
    public let content: Content

    public init(width: Float? = 300,
                configure: (inout Self) -> Void = { _ in },
                @ViewBuilder label: () -> Label,
                @ViewBuilder content: () -> Content) {
        self.width = width
        self.openDelay = 0.3
        self.closeDelay = 0.15
        self.isEnabled = true
        self.label = label()
        self.content = content()
        configure(&self)
    }

    public var body: some View {
        Box(direction: .column, alignItems: .flexStart, spacing: 0) {
            label.onHover { triggerHovered = $0 }
            // Zero-sized, and placed before the overlay host so the host's
            // "nearest visible preceding sibling" anchor still resolves to the
            // label rather than to this bookkeeping node.
            _HoverIntent(wantsPresented: isEnabled && (triggerHovered || cardHovered),
                         isPresented: $isPresented,
                         openDelay: openDelay,
                         closeDelay: closeDelay)
            _PopoverOverlayHost(isPresented: isPresented && isEnabled,
                                width: width,
                                placement: .start,
                                onDismiss: { isPresented = false }) {
                ThemeReader { theme in
                    Box(direction: .column, alignItems: .stretch, spacing: 0) { content }
                        .padding(theme.spacing.md)
                        .background(.materialFloating)
                        .cornerRadius(theme.radius.md)
                        .backdropBlur(14)
                        .border(SemanticColorRef.border, width: 1)
                        .floatingSurface()
                        .onHover { cardHovered = $0 }
                }
            }
        }
        .zIndex(isPresented ? 10_000 : 0)
    }
}

/// Turns hover intent into presentation after a delay.
///
/// The delay runs on the animation scheduler rather than a timer: it advances
/// with the frame clock, so it pauses with the window and needs no thread hop
/// to write the binding.
private struct _HoverIntent: _PrimitiveView {
    let wantsPresented: Bool
    let isPresented: Binding<Bool>
    let openDelay: Double
    let closeDelay: Double

    private enum Keys {
        static let target = "hoverCard.intentTarget"
        static let controller = "hoverCard.controller"
    }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.width = 0
        layout.height = 0
        return layout
    }

    func _updateNode(_ node: Node) {
        guard node.attachments[Keys.target] as? Bool != wantsPresented else { return }
        node.attachments[Keys.target] = wantsPresented
        cancelPending(in: node)
        guard wantsPresented != isPresented.wrappedValue else { return }
        let delay = wantsPresented ? openDelay : closeDelay
        guard delay > 0 else {
            isPresented.wrappedValue = wantsPresented
            return
        }
        let controller = AnimationController<Float>(
            from: 0,
            to: 1,
            animation: Animation(duration: delay, curve: .linear),
            apply: { value in
                guard value >= 1 else { return }
                if isPresented.wrappedValue != wantsPresented { isPresented.wrappedValue = wantsPresented }
            })
        node.attachments[Keys.controller] = controller
        AnimatorScheduler.current.register(controller)
    }

    private func cancelPending(in node: Node) {
        guard let controller = node.attachments[Keys.controller] as? AnyAnimationController else { return }
        controller.cancel()
        AnimatorScheduler.current.unregister(controller)
        node.attachments.removeValue(forKey: Keys.controller)
    }
}
