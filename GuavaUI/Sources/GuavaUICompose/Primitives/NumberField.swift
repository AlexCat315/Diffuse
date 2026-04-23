import Foundation
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

    public init(value: Binding<Float>,
                decimals: Int = 2,
                size: TextField.Size = .regular,
                isEnabled: Bool = true,
                minValue: Float? = nil,
                maxValue: Float? = nil,
                step: Float? = nil,
                showsStepper: Bool = false) {
        self.value = value
        self.decimals = max(0, min(decimals, 6))
        self.size = size
        self.isEnabled = isEnabled
        self.minValue = minValue
        self.maxValue = maxValue
        self.step = step
        self.showsStepper = showsStepper
    }

    public var body: some View {
        _StatefulNumberField(field: self)
    }

    static func format(_ value: Float, decimals: Int) -> String {
        let clamped = max(0, min(decimals, 6))
        let formatted = String(format: "%.*f", clamped, value)
        guard clamped > 0 else { return formatted }

        var trimmed = formatted
        while trimmed.last == "0" {
            trimmed.removeLast()
        }
        if trimmed.last == "." {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? "0" : trimmed
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

    @State var draft: String = ""
    @State var isEditing: Bool = false

    var body: some View {
        let committed = NumberField.format(normalized(field.value.wrappedValue), decimals: field.decimals)
        let input = TextField(
            text: Binding(
                get: { isEditing ? draft : committed },
                set: { draft = $0 }
            ),
            size: field.size,
            disabled: !field.isEnabled,
            onSubmit: {
                commitDraft()
            },
            onFocus: {
                if !isEditing {
                    draft = committed
                    isEditing = true
                }
            },
            onBlur: {
                commitDraft()
                isEditing = false
            }
        )

        guard field.showsStepper else {
            return AnyView(input)
        }

        return AnyView(
            Row(alignment: .center, spacing: 4) {
                input
                    .flex()
                Button(role: .normal,
                       isEnabled: field.isEnabled,
                       action: { decrement() }) {
                    Text("-")
                        .font(.label)
                        .frame(width: 12)
                }
                .buttonStyle(.ghost)
                .frame(width: 18, height: 18)

                Button(role: .normal,
                       isEnabled: field.isEnabled,
                       action: { increment() }) {
                    Text("+")
                        .font(.label)
                        .frame(width: 12)
                }
                .buttonStyle(.ghost)
                .frame(width: 18, height: 18)
            }
        )
    }

    private func commitDraft() {
        if let parsed = NumberField.parse(draft) {
            let next = normalized(parsed)
            if field.value.wrappedValue != next {
                field.value.wrappedValue = next
            }
        }
        let committed = normalized(field.value.wrappedValue)
        if committed != field.value.wrappedValue {
            field.value.wrappedValue = committed
        }
        draft = NumberField.format(committed, decimals: field.decimals)
    }

    private func increment() {
        let step = resolvedStep
        let next = normalized(field.value.wrappedValue + step)
        if field.value.wrappedValue != next {
            field.value.wrappedValue = next
        }
        draft = NumberField.format(next, decimals: field.decimals)
    }

    private func decrement() {
        let step = resolvedStep
        let next = normalized(field.value.wrappedValue - step)
        if field.value.wrappedValue != next {
            field.value.wrappedValue = next
        }
        draft = NumberField.format(next, decimals: field.decimals)
    }

    private var resolvedStep: Float {
        guard let step = field.step, step > 0 else { return 1 }
        return step
    }

    private func normalized(_ value: Float) -> Float {
        let clamped = clamped(value)
        guard let step = field.step, step > 0 else { return clamped }
        let base = field.minValue ?? 0
        let snapped = ((clamped - base) / step).rounded() * step + base
        return clampedValue(snapped)
    }

    private func clamped(_ value: Float) -> Float {
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
