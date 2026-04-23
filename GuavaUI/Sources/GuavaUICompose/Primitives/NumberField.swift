import Foundation
import GuavaUIRuntime

/// Numeric text field that keeps an editable draft and commits parsed floats on submit or blur.
public struct NumberField: View {
    public let value: Binding<Float>
    public let decimals: Int
    public let size: TextField.Size
    public let isEnabled: Bool

    public init(value: Binding<Float>,
                decimals: Int = 2,
                size: TextField.Size = .regular,
                isEnabled: Bool = true) {
        self.value = value
        self.decimals = max(0, min(decimals, 6))
        self.size = size
        self.isEnabled = isEnabled
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
        let committed = NumberField.format(field.value.wrappedValue, decimals: field.decimals)

        return TextField(
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
    }

    private func commitDraft() {
        if let parsed = NumberField.parse(draft), field.value.wrappedValue != parsed {
            field.value.wrappedValue = parsed
        }
        draft = NumberField.format(field.value.wrappedValue, decimals: field.decimals)
    }
}
