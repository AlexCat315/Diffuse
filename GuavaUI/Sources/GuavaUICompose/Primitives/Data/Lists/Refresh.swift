import GuavaUIRuntime

/// Pull-to-refresh configuration for `List` and `VirtualStack`.
///
/// The caller owns the asynchronous work: `action` starts it, and
/// `isRefreshing` drives the indicator until the work finishes. The indicator
/// appears when the touch pull crosses `threshold`, and Cmd+R / Ctrl+R invokes
/// the same action while focus is inside the list.
public struct RefreshOptions {
    public let isRefreshing: Binding<Bool>
    public let threshold: Float
    public let action: () -> Void

    public init(isRefreshing: Binding<Bool>,
                threshold: Float = 64,
                action: @escaping () -> Void) {
        self.isRefreshing = isRefreshing
        self.threshold = threshold.isFinite ? max(24, threshold) : 64
        self.action = action
    }
}

/// Top-of-viewport pull affordance. The spinner freezes under reduced motion
/// through `Spinner`; the label remains readable without animation.
struct RefreshIndicator: View {
    let pull: CGFloat
    let threshold: CGFloat
    let isRefreshing: Bool

    private var progress: CGFloat {
        guard threshold > 0 else { return 0 }
        return min(1, max(0, pull / threshold))
    }

    var body: some View {
        ThemeReader { theme in
            Box(direction: .row, alignItems: .center, justifyContent: .center, spacing: 6) {
                if isRefreshing {
                    Spinner(size: 14, isAnimating: true)
                } else {
                    Icon(UIIcons.Navigation.arrowDown, size: 14,
                         color: progress >= 1 ? .accent : .onSurfaceMuted)
                }
                if isRefreshing || pull > 24 {
                    Text(isRefreshing ? "Refreshing" : "Release to refresh")
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
            }
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
            .background(theme.colors.surfaceVariant)
            .cornerRadius(16)
            .opacity(isRefreshing || pull > 4 ? 1 : 0)
            .debugName("refresh-indicator")
            .allowsHitTesting(false)
        }
    }
}

/// Cmd+R (macOS) / Ctrl+R is the non-touch path. It lives on the subtree root
/// so keys from a focused row or the ScrollView bubble here.
struct RefreshKeyboardModifier: ViewModifier {
    let refresh: RefreshOptions?

    func apply(node: Node) {
        guard let refresh, let registry = InteractionRegistryHolder.current else { return }
        registry.setKey(node) { event, phase in
            guard phase != .capture,
                  event.scancode == Scancode.r,
                  !event.modifiers.isDisjoint(with: [.gui, .ctrl]) else { return .ignored }
            if !refresh.isRefreshing.wrappedValue { refresh.action() }
            return .handled
        }
    }
}
