import Foundation
import GuavaUIRuntime

/// A button that opens a menu anchored to itself. Uses the regular `Popover`
/// trigger contract, so the menu escapes clipping, closes on Escape/outside
/// click and exposes expanded state to accessibility.
public struct MenuButton<Label: View>: View {
    public let entries: [MenuEntry]
    public let isEnabled: Bool
    public let width: Float?
    public let placement: PopoverPlacement
    public let label: Label
    public let accessibilityLabel: String?
    public let tooltip: String?

    @State private var presented = false

    public init(entries: [MenuEntry],
                isEnabled: Bool = true,
                width: Float? = nil,
                placement: PopoverPlacement = .bottomLeading,
                accessibilityLabel: String? = nil,
                tooltip: String? = nil,
                @ViewBuilder label: () -> Label) {
        self.entries = entries
        self.isEnabled = isEnabled
        self.width = width
        self.placement = placement
        self.accessibilityLabel = accessibilityLabel
        self.tooltip = tooltip
        self.label = label()
    }

    public var body: some View {
        var popover = Popover(isPresented: $presented,
                              isEnabled: isEnabled,
                              width: width,
                              placement: placement,
                              surface: .content, overflow: .flip, triggerStyle: AnyButtonStyle(SecondaryButtonStyle()),
                              label: { label }) {
            Menu(entries, width: width, onItemActivated: { presented = false })
        }
        if let accessibilityLabel {
            popover.triggerDescription = PopoverTriggerDescription(label: accessibilityLabel, help: tooltip)
        }
        return popover
    }
}

public extension MenuButton where Label == Text {
    init(_ title: String,
         entries: [MenuEntry],
         isEnabled: Bool = true,
         width: Float? = nil,
         placement: PopoverPlacement = .bottomLeading,
         tooltip: String? = nil) {
        self.init(entries: entries, isEnabled: isEnabled, width: width, placement: placement,
                  accessibilityLabel: title, tooltip: tooltip) {
            Text(title).truncatingTail()
        }
    }
}
