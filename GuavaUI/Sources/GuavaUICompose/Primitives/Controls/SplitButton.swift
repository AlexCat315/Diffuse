import Foundation
import GuavaUIRuntime

/// Primary action plus an adjacent menu trigger. The primary button runs the
/// default action; the arrow opens the same `MenuEntry` menu used by
/// `MenuButton`.
public struct SplitButton<Label: View>: View {
    public let label: Label
    public let action: () -> Void
    public let entries: [MenuEntry]
    public let isEnabled: Bool
    public let menuWidth: Float?

    public init(entries: [MenuEntry],
                isEnabled: Bool = true,
                menuWidth: Float? = nil,
                action: @escaping () -> Void,
                @ViewBuilder label: () -> Label) {
        self.label = label()
        self.action = action
        self.entries = entries
        self.isEnabled = isEnabled
        self.menuWidth = menuWidth
    }

    public var body: some View {
        Box(direction: .row, alignItems: .stretch, spacing: 0) {
            Button(isEnabled: isEnabled, action: action) { label }
                .buttonStyle(.secondary)
                .flex(1, shrink: 1, basis: 0)
            Box {}.frame(width: 1).background(.border)
            MenuButton(entries: entries, isEnabled: isEnabled, width: menuWidth,
                       accessibilityLabel: "More actions") {
                Icon(UIIcons.Navigation.chevronDown, size: .small)
                    .padding(horizontal: 10, vertical: 7)
            }
        }
        .frame(minHeight: 32)
        .modifier(_SplitButtonGroupModifier())
    }
}

/// One Tab stop for the pair. Left/Right moves between the primary and menu
/// zones while preserving the focused button; the divider is shared chrome,
/// not a third control.
private struct _SplitButtonGroupModifier: ViewModifier {
    func apply(node: Node) {
        node.layoutDidUpdate = { node in
            applyTabStops(in: node, zone: node.attachments["split.zone"] as? Int ?? 0)
        }
        guard let registry = InteractionRegistryHolder.current else { return }
        registry.setKey(node) { [weak node] event, phase in
            guard phase == .bubble, let node, event.modifiers.isEmpty else { return .ignored }
            switch event.scancode {
            case Scancode.arrowRight, Scancode.arrowLeft:
                guard let current = FocusChainHolder.current?.focused,
                      let buttons = buttons(in: node),
                      let index = buttons.firstIndex(where: { $0 === current }) else { return .ignored }
                let target = event.scancode == Scancode.arrowRight
                    ? buttons[min(1, index + 1)] : buttons[max(0, index - 1)]
                let zone = target === buttons[1] ? 1 : 0
                node.attachments["split.zone"] = zone
                applyTabStops(in: node, zone: zone)
                FocusChainHolder.current?.focus(target)
                return .handled
            default: return .ignored
            }
        }
    }

    private func buttons(in node: Node) -> [Node]? {
        var found: [Node] = []
        func walk(_ candidate: Node) {
            if candidate.isFocusable, candidate.attachments[ButtonHost.markerKey] != nil {
                found.append(candidate)
            }
            for child in candidate.children { walk(child) }
        }
        walk(node)
        return found.count >= 2 ? Array(found.prefix(2)) : nil
    }

    private func applyTabStops(in node: Node, zone: Int) {
        guard let buttons = buttons(in: node) else { return }
        buttons[0].isTabStop = zone == 0
        buttons[1].isTabStop = zone == 1
    }
}

public extension SplitButton where Label == Text {
    init(_ title: String,
         entries: [MenuEntry],
         isEnabled: Bool = true,
         menuWidth: Float? = nil,
         action: @escaping () -> Void) {
        self.init(entries: entries, isEnabled: isEnabled, menuWidth: menuWidth, action: action) {
            Text(title)
        }
    }
}
