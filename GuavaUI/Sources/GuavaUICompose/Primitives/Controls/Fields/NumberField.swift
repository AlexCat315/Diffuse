import Foundation
import EngineKernel
import GuavaUIRuntime

/// Numeric text field that keeps an editable draft and commits parsed floats on submit or blur.
public struct NumberField: View {
    public let value: Binding<Float>
    public let decimals: Int
    public let size: TextField.Size
    public let isEnabled: Bool
    public let minValue: Float?
    public let maxValue: Float?
    public let step: Float?
    public let showsStepper: Bool
    public let mixedValueLabel: String?

    public init(value: Binding<Float>,
                decimals: Int = 2,
                size: TextField.Size = .automatic,
                isEnabled: Bool = true,
                minValue: Float? = nil,
                maxValue: Float? = nil,
                step: Float? = nil,
                showsStepper: Bool = false,
                mixedValueLabel: String? = nil) {
        self.value = value
        self.decimals = max(0, min(decimals, 6))
        self.size = size
        self.isEnabled = isEnabled
        self.minValue = minValue
        self.maxValue = maxValue
        self.step = step
        self.showsStepper = showsStepper
        self.mixedValueLabel = mixedValueLabel
    }

    public var body: some View {
        _StatefulNumberField(field: self)
    }

    static func format(_ value: Float, decimals: Int) -> String {
        let clamped = max(0, min(decimals, 6))
        let formatted = String(format: "%.*f", clamped, value)
        guard clamped > 0 else { return formatted == "-0" ? "0" : formatted }

        var trimmed = formatted
        while trimmed.last == "0" {
            trimmed.removeLast()
        }
        if trimmed.last == "." {
            trimmed.removeLast()
        }
        return trimmed.isEmpty || trimmed == "-0" ? "0" : trimmed
    }

    static func parse(_ text: String) -> Float? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let parsed = Float(trimmed),
              parsed.isFinite
        else {
            return nil
        }
        return parsed
    }
}

private struct _StatefulNumberField: View {
    let field: NumberField

    @State var draft = TextBuffer.empty
    @State var isEditing: Bool = false
    @State var draftChanged: Bool = false

    var body: some View {
        let committed = field.mixedValueLabel == nil
            ? NumberField.format(normalized(field.value.wrappedValue), decimals: field.decimals) : ""
        let committedBuffer = TextBuffer(committed)
        let input = TextField(field.mixedValueLabel ?? "", text: Binding(
                get: { isEditing ? draft : committedBuffer },
                set: { draft = $0; draftChanged = true }
            )) { input in
            input.decoration.size = field.size
            input.behavior.disabled = !field.isEnabled
            input.events.onSubmit = {
                commitDraft()
            }
            input.events.onKeyDown = { event in
                guard event.scancode == Scancode.arrowUp || event.scancode == Scancode.arrowDown else { return false }
                let multiplier: Float = !event.modifiers.isDisjoint(with: .shift) ? 10
                    : (!event.modifiers.isDisjoint(with: .alt) ? 0.1 : 1)
                adjust(by: event.scancode == Scancode.arrowUp ? multiplier : -multiplier)
                return true
            }
            input.events.onFocus = {
                if !isEditing {
                    draft = committedBuffer
                    draftChanged = false
                    isEditing = true
                }
            }
            input.events.onBlur = {
                commitDraft()
                isEditing = false
            }
        }

        guard field.showsStepper else {
            return AnyView(input)
        }

        // Optional compact spinner. Inspector fields use keyboard stepping.
        return AnyView(
            Row(alignment: .center, spacing: 2) {
                input
                    .flex()
                Box(direction: .column, alignItems: .stretch, spacing: 1) {
                    stepButton(UICommonIcons.chevronUp) { increment() }
                    stepButton(UICommonIcons.chevronDown) { decrement() }
                }
            }
        )
    }

    private func stepButton(_ icon: BundleImageResource,
                            action: @escaping () -> Void) -> some View {
        Button(role: .normal,
               isEnabled: field.isEnabled,
               action: action) {
            Icon(icon, size: 7, color: .onSurfaceMuted)
        }
        .buttonStyle(.plain)
        .frame(width: 20, height: 14)
    }

    private func commitDraft() {
        guard draftChanged else { return }
        draftChanged = false
        if let parsed = NumberField.parse(draft.stringValue) {
            let next = normalized(parsed)
            if field.mixedValueLabel != nil || field.value.wrappedValue != next {
                field.value.wrappedValue = next
            }
        }
        let committed = normalized(field.value.wrappedValue)
        if committed != field.value.wrappedValue {
            field.value.wrappedValue = committed
        }
        draft = TextBuffer(NumberField.format(committed, decimals: field.decimals))
    }

    private func increment() {
        adjust(by: 1)
    }

    private func decrement() {
        adjust(by: -1)
    }

    private func adjust(by multiplier: Float) {
        let current = isEditing ? NumberField.parse(draft.stringValue) ?? field.value.wrappedValue : field.value.wrappedValue
        let next = normalized(current + resolvedStep * multiplier)
        if field.value.wrappedValue != next {
            field.value.wrappedValue = next
        }
        draft = TextBuffer(NumberField.format(next, decimals: field.decimals))
        draftChanged = false
    }

    private var resolvedStep: Float {
        guard let step = field.step, step.isFinite, step > 0 else { return 1 }
        return step
    }

    private func normalized(_ value: Float) -> Float {
        // Step is an increment, not a quantization rule for typed values.
        clampedValue(value)
    }

    private func clampedValue(_ value: Float) -> Float {
        var out = value
        if let minValue = field.minValue {
            out = max(minValue, out)
        }
        if let maxValue = field.maxValue {
            out = min(maxValue, out)
        }
        return out
    }
}
