import Foundation
import GuavaUIRuntime

/// Search input built on the regular `TextField` chrome: a decorative leading
/// search icon, the field's clear affordance, submit and Escape handling, and
/// an optional suggestion list that supports arrow keys, Return and pointer.
public struct SearchField: View {
    public let text: Binding<TextBuffer>
    public let placeholder: String
    public let suggestions: [String]
    public let isEnabled: Bool
    public let clearsOnEscape: Bool
    public let onSubmit: ((String) -> Void)?
    public let onSuggestionSelected: ((String) -> Void)?

    @State private var highlighted: Int?
    @State private var isFocused = false
    @State private var suppressSuggestions = false

    public init(text: Binding<TextBuffer>,
                placeholder: String = "Search",
                suggestions: [String] = [],
                isEnabled: Bool = true,
                clearsOnEscape: Bool = true,
                onSubmit: ((String) -> Void)? = nil,
                onSuggestionSelected: ((String) -> Void)? = nil) {
        self.text = text
        self.placeholder = placeholder
        self.suggestions = suggestions
        self.isEnabled = isEnabled
        self.clearsOnEscape = clearsOnEscape
        self.onSubmit = onSubmit
        self.onSuggestionSelected = onSuggestionSelected
    }

    public var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 4) {
            TextField(placeholder, text: text) { input in
                input.decoration.leadingIcon = UIIcons.Action.search
                input.behavior.clearable = true
                input.behavior.disabled = !isEnabled
                input.events.onSubmit = { submit() }
                input.events.onKeyDown = { event in handle(event) }
                input.events.onChange = { buffer in
                    suppressSuggestions = false
                    highlighted = matches(buffer.stringValue).isEmpty ? nil : 0
                }
                input.events.onFocus = {
                    isFocused = true
                    suppressSuggestions = false
                    if highlighted == nil, !matches(text.wrappedValue.stringValue).isEmpty {
                        highlighted = 0
                    }
                }
                input.events.onBlur = { isFocused = false; highlighted = nil }
                input.events.onClear = { highlighted = nil }
            }
            .accessibilityLabel("Search")

            if showsSuggestions {
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    for (index, suggestion) in visibleSuggestions.enumerated() {
                        AnyView(Button(suggestion, isSelected: index == highlighted) {
                            choose(suggestion)
                        }.buttonStyle(SuggestionRowStyle()))
                    }
                }
                .background(.surfaceFloating)
                .cornerRadius(.controlRadius)
                .border(.border, width: 1)
            }
        }
    }

    private var visibleSuggestions: [String] {
        matches(text.wrappedValue.stringValue)
    }

    private var showsSuggestions: Bool {
        !suppressSuggestions && isEnabled
            && (isFocused || !text.wrappedValue.stringValue.isEmpty)
            && !visibleSuggestions.isEmpty
    }

    private func matches(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return suggestions }
        return suggestions.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private func handle(_ event: KeyEvent) -> Bool {
        switch event.scancode {
        case Scancode.arrowDown:
            move(1)
            return true
        case Scancode.arrowUp:
            move(-1)
            return true
        case Scancode.escape:
            guard clearsOnEscape else { return false }
            text.wrappedValue = TextBuffer("")
            highlighted = nil
            return true
        case Scancode.return, Scancode.keypadEnter:
            if let highlighted, visibleSuggestions.indices.contains(highlighted) {
                choose(visibleSuggestions[highlighted])
            } else {
                submit()
            }
            return true
        default:
            return false
        }
    }

    private func move(_ delta: Int) {
        let items = visibleSuggestions
        guard !items.isEmpty else { return }
        let current = highlighted ?? (delta > 0 ? -1 : items.count)
        highlighted = max(0, min(items.count - 1, current + delta))
    }

    private func choose(_ suggestion: String) {
        text.wrappedValue = TextBuffer(suggestion)
        highlighted = nil
        isFocused = false
        suppressSuggestions = true
        onSuggestionSelected?(suggestion)
    }

    private func submit() {
        onSubmit?(text.wrappedValue.stringValue)
    }
}


/// Fills the row and keeps the label at the leading edge; a plain `.ghost`
/// button style centers its label, which reads as a menu title rather than a
/// suggestion.
private struct SuggestionRowStyle: ButtonStyle {
    func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        Box(direction: .row, alignItems: .center, justifyContent: .flexStart) {
            AnyView(c.label)
        }
        .frame(width: .percent(100))
        .padding(horizontal: 10, vertical: 8)
        .background(c.isSelected ? c.theme.colors.stateLayerSelected
                    : c.isHovered ? c.theme.colors.stateLayerHover
                    : .clear)
            .animation(motion: .fast, value: c.interactionKey)
    }
}
