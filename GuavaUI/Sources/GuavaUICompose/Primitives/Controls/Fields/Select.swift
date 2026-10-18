import EngineKernel
import Foundation
import GuavaUIRuntime

public enum KeyboardShortcutPlatform: Sendable, Equatable {
    case macOS
    case windows
    case linux
    case other

    public static var current: KeyboardShortcutPlatform {
        #if os(macOS)
        return .macOS
        #elseif os(Windows)
        return .windows
        #elseif os(Linux)
        return .linux
        #else
        return .other
        #endif
    }
}

public enum KeyboardShortcutModifier: Sendable, Equatable, Hashable {
    case primary
    case command
    case control
    case option
    case shift
}

public struct KeyboardShortcut: Sendable, Equatable, Hashable {
    public var modifiers: [KeyboardShortcutModifier]
    public var key: String

    public init(_ key: String, modifiers: [KeyboardShortcutModifier] = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public static func primary(_ key: String) -> KeyboardShortcut {
        KeyboardShortcut(key, modifiers: [.primary])
    }

    public static func primaryShift(_ key: String) -> KeyboardShortcut {
        KeyboardShortcut(key, modifiers: [.primary, .shift])
    }

    public var displayString: String {
        displayString(platform: .current)
    }

    public func displayString(platform: KeyboardShortcutPlatform) -> String {
        let caps = caps(platform: platform)
        switch platform {
        case .macOS:
            return caps.joined()
        case .windows, .linux, .other:
            return caps.joined(separator: "+")
        }
    }

    /// The shortcut split into the individual glyphs a `KeyCap` draws.
    /// Modifiers come first in the platform's canonical order, then the key.
    public func caps(platform: KeyboardShortcutPlatform = .current) -> [String] {
        resolvedModifiers(for: platform).map { modifierDisplay($0, platform: platform) } + [key]
    }

    private func resolvedModifiers(for platform: KeyboardShortcutPlatform) -> [KeyboardShortcutModifier] {
        var resolved: [KeyboardShortcutModifier] = []
        for modifier in modifiers {
            let platformModifier: KeyboardShortcutModifier
            if modifier == .primary {
                platformModifier = platform == .macOS ? .command : .control
            } else {
                platformModifier = modifier
            }
            if !resolved.contains(platformModifier) {
                resolved.append(platformModifier)
            }
        }
        return resolved
    }

    private func modifierDisplay(_ modifier: KeyboardShortcutModifier,
                                 platform: KeyboardShortcutPlatform) -> String {
        switch platform {
        case .macOS:
            switch modifier {
            case .primary, .command: return "⌘"
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            }
        case .windows, .linux, .other:
            switch modifier {
            case .primary, .control: return "Ctrl"
            case .command: return "Meta"
            case .option: return "Alt"
            case .shift: return "Shift"
            }
        }
    }
}

public struct SelectOption<Value: Hashable>: Identifiable {
    public let value: Value
    public let label: String
    public let isEnabled: Bool

    public var id: AnyHashable { AnyHashable(value) }

    public init(value: Value,
                label: String,
                isEnabled: Bool = true) {
        self.value = value
        self.label = label
        self.isEnabled = isEnabled
    }
}

public struct Select<Value: Hashable>: View {
    public let selection: Binding<Value>
    public let options: [SelectOption<Value>]
    public let isEnabled: Bool
    public let width: Float?
    public let maxVisibleRows: Int
    public let placeholder: String

    public init(selection: Binding<Value>,
                options: [SelectOption<Value>],
                isEnabled: Bool = true,
                width: Float? = nil,
                maxVisibleRows: Int = 8,
                placeholder: String = "Select") {
        self.selection = selection
        self.options = options
        self.isEnabled = isEnabled
        self.width = width
        self.maxVisibleRows = max(1, maxVisibleRows)
        self.placeholder = placeholder
    }

    public var body: some View {
        _StatefulSelect(select: self)
    }
}

private struct _StatefulSelect<Value: Hashable>: View {
    let select: Select<Value>

    @State var isPresented: Bool = false
    @State var isHovered: Bool = false
    @State private var chromeWidth: Float = 0

    var body: some View {
        ThemeReader { theme in
        var popover = Popover(isPresented: $isPresented,
                isEnabled: select.isEnabled,
                width: select.width,
                surface: .content, overflow: .flip, label: {
            // Trigger reads as a text input: same sunken fill, border, and
            // radius the TextField/NumberField use (theme.inputs), so a Select
            // sits flush with the fields around it in a property grid instead
            // of looking like a lighter pill from an older style.
            //
            // Open state changes the border *colour* at the normal hairline
            // width. It used to widen to the 2pt focus ring, which read as a
            // second, louder control sitting under the popup; the ring is now
            // reserved for keyboard focus, which the trigger style draws.
            InlineLabelLayout(spacing: 8, onMinimumWidth: { width in
                if chromeWidth != Float(width) { chromeWidth = Float(width) }
            }) {
                Box {}
                Text(selectedLabel).truncatingTail()
                    .font(.body)
                    .foregroundColor(select.isEnabled ? .onSurface : .onSurfaceDisabled)
                    .accessibilityHidden()
                Icon(isPresented ? UIIcons.Navigation.chevronUp : UIIcons.Navigation.chevronDown, size: .small, color: .onSurfaceMuted)
                    .accessibilityHidden()
            }
            .padding(horizontal: 10, vertical: 6)
            .frame(minHeight: 32)
            .background(theme.inputs.background)
            .cornerRadius(theme.inputs.radius)
            .border(borderColor(theme), width: theme.inputs.borderWidth)
            .animation(.semantic(.fast, in: theme), value: isPresented)
            .animation(.semantic(.fast, in: theme), value: isHovered)
            .onHover { hovered in
                if isHovered != hovered { isHovered = hovered }
            }
        }, content: {
            Menu(menuEntries,
                 maxVisibleRows: select.maxVisibleRows,
                 onItemActivated: {
                isPresented = false
            })
        })
        popover.sizing = .anchor
        popover.triggerDescription = .init(label: selectedLabel,
            value: select.options.first(where: { $0.value == select.selection.wrappedValue })?.label ?? "", help: selectedLabel)
        return popover.frame(minWidth: max(44, chromeWidth + 24 + theme.inputs.borderWidth * 2))
            .compositionLocal(ActionControlAccessibility.role, .comboBox)
        }
    }

    /// Open beats hover: the popup is open because of the trigger, so the
    /// trigger has to explain it even while the pointer has moved into the menu.
    private func borderColor(_ theme: Theme) -> Color {
        guard select.isEnabled else { return theme.inputs.borderDisabled }
        if isPresented { return theme.inputs.borderFocused }
        return isHovered ? theme.inputs.borderHover : theme.inputs.borderColor
    }

    private var selectedLabel: String {
        if let matched = select.options.first(where: { $0.value == select.selection.wrappedValue }) {
            return matched.label
        }
        return select.placeholder
    }

    private var menuEntries: [MenuEntry] {
        select.options.map { option in
            .item(MenuItem(
                id: option.id,
                title: option.label,
                isEnabled: option.isEnabled,
                isSelected: option.value == select.selection.wrappedValue,
                role: .normal,
                action: {
                    select.selection.wrappedValue = option.value
                }
            ))
        }
    }
}

public struct EnumField<Value: Hashable & CaseIterable>: View where Value.AllCases: Collection {
    public let value: Binding<Value>
    public let isEnabled: Bool
    public let width: Float?
    public let maxVisibleRows: Int
    public let label: (Value) -> String

    public init(value: Binding<Value>,
                isEnabled: Bool = true,
                width: Float? = nil,
                maxVisibleRows: Int = 8,
                label: @escaping (Value) -> String = { String(describing: $0) }) {
        self.value = value
        self.isEnabled = isEnabled
        self.width = width
        self.maxVisibleRows = max(1, maxVisibleRows)
        self.label = label
    }

    public var body: some View {
        Select(selection: value,
               options: options,
               isEnabled: isEnabled,
               width: width,
               maxVisibleRows: maxVisibleRows,
               placeholder: "Select")
    }

    private var options: [SelectOption<Value>] {
        Array(Value.allCases).map { option in
            SelectOption(value: option, label: label(option), isEnabled: true)
        }
    }
}

private extension View {
    @ViewBuilder
    func ifLet<T>(_ value: T?,
                  transform: (Self, T) -> some View) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}
