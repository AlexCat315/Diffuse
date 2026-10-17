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
            MenuButton(entries: entries, isEnabled: isEnabled, width: menuWidth,
                       accessibilityLabel: "More actions") {
                Icon(UIIcons.Navigation.chevronDown, size: .small)
                    .padding(horizontal: 10, vertical: 7)
            }
        }
        .frame(minHeight: 32)
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
