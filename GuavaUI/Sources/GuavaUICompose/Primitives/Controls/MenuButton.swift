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

    @State private var presented = false

    public init(entries: [MenuEntry],
                isEnabled: Bool = true,
                width: Float? = nil,
                placement: PopoverPlacement = .start,
                @ViewBuilder label: () -> Label) {
        self.entries = entries
        self.isEnabled = isEnabled
        self.width = width
        self.placement = placement
        self.label = label()
    }

    public var body: some View {
        Popover(isPresented: $presented,
                isEnabled: isEnabled,
                width: width,
                placement: placement,
                triggerStyle: AnyButtonStyle(SecondaryButtonStyle()),
                label: { label }) {
            Menu(entries, width: width, onItemActivated: { presented = false })
        }
    }
}

public extension MenuButton where Label == Text {
    init(_ title: String,
         entries: [MenuEntry],
         isEnabled: Bool = true,
         width: Float? = nil,
         placement: PopoverPlacement = .start) {
        self.init(entries: entries, isEnabled: isEnabled, width: width, placement: placement) {
            Text(title)
        }
    }
}
