import Foundation
import GuavaUIRuntime

public enum JsonFieldValidation: Equatable, Sendable {
    case valid
    case empty
    case invalid(String)

    public var isAcceptable: Bool {
        switch self {
        case .valid, .empty:
            return true
        case .invalid:
            return false
        }
    }
}

public struct JsonField: View {
    public let text: Binding<String>
    public let placeholder: String
    public let minHeight: Float
    public let isEnabled: Bool
    public let onCommit: ((String) -> Void)?

    public init(text: Binding<String>,
                placeholder: String = "{}",
                minHeight: Float = 96,
                isEnabled: Bool = true,
                onCommit: ((String) -> Void)? = nil) {
        self.text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
        self.isEnabled = isEnabled
        self.onCommit = onCommit
    }

    public var body: some View {
        _StatefulJsonField(field: self)
    }

    public static func normalizedCommitText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "{}" : trimmed
    }

    public static func validate(_ text: String) -> JsonFieldValidation {
        let normalized = normalizedCommitText(text)
        guard let data = normalized.data(using: .utf8) else {
            return .invalid("Input is not valid UTF-8")
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
            return normalized == "{}" && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .empty
                : .valid
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    public static func prettyPrinted(_ text: String) -> String? {
        let normalized = normalizedCommitText(text)
        guard let data = normalized.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let prettyData = try? JSONSerialization.data(withJSONObject: object,
                                                           options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8)
        else {
            return nil
        }
        return pretty
    }
}

private struct _StatefulJsonField: View {
    let field: JsonField

    @State var draft: String = ""
    @State var isEditing: Bool = false
    @State var validation: JsonFieldValidation = .valid

    var body: some View {
        let currentValidation = isEditing ? validation : JsonField.validate(field.text.wrappedValue)

        Box(direction: .column, alignItems: .stretch, spacing: 6) {
            TextField(field.placeholder,
                      text: Binding(
                        get: { isEditing ? draft : field.text.wrappedValue },
                        set: { next in
                            draft = next
                            validation = JsonField.validate(next)
                        }
                      ),
                      axis: .vertical,
                      disabled: !field.isEnabled,
                      onSubmit: {
                        commitDraft()
                      },
                      onFocus: {
                        if !isEditing {
                            draft = field.text.wrappedValue.isEmpty ? "{}" : field.text.wrappedValue
                            validation = JsonField.validate(draft)
                            isEditing = true
                        }
                      },
                      onBlur: {
                        commitDraft()
                        isEditing = false
                      })
                .font(.mono)
                .frame(minHeight: field.minHeight)
                .border(borderColor(for: currentValidation), width: 1)
                .cornerRadius(4)
                .clipped()

            Row(alignment: .center, spacing: 6) {
                validationStatus(currentValidation)
                    .flex(1, shrink: 1, basis: 0)

                Button(role: .normal,
                       isEnabled: field.isEnabled && currentValidation.isAcceptable,
                       action: {
                    formatDraft()
                }) {
                    Text("Format")
                        .font(.caption)
                        .foregroundColor(.onSurfaceVariant)
                }
                .buttonStyle(.ghost)

                Button(role: .normal,
                       isEnabled: field.isEnabled,
                       action: {
                    draft = field.text.wrappedValue
                    validation = JsonField.validate(draft)
                    isEditing = false
                }) {
                    Text("Revert")
                        .font(.caption)
                        .foregroundColor(.onSurfaceVariant)
                }
                .buttonStyle(.ghost)
            }
        }
    }

    private func validationStatus(_ validation: JsonFieldValidation) -> some View {
        switch validation {
        case .valid:
            return AnyView(
                Text("Valid JSON")
                    .font(.caption)
                    .foregroundColor(.success)
            )
        case .empty:
            return AnyView(
                Text("Empty saves as {}")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            )
        case let .invalid(message):
            return AnyView(
                Text(message)
                    .font(.caption)
                    .foregroundColor(.error)
                    .clipped()
            )
        }
    }

    private func borderColor(for validation: JsonFieldValidation) -> Color {
        switch validation {
        case .valid, .empty:
            return Color(red: 58, green: 64, blue: 78)
        case .invalid:
            return Color(red: 233, green: 89, blue: 89)
        }
    }

    private func commitDraft() {
        let candidate = isEditing ? draft : field.text.wrappedValue
        let result = JsonField.validate(candidate)
        validation = result
        guard result.isAcceptable else { return }
        let normalized = JsonField.normalizedCommitText(candidate)
        if field.text.wrappedValue != normalized {
            field.text.wrappedValue = normalized
        }
        field.onCommit?(normalized)
        draft = normalized
    }

    private func formatDraft() {
        let candidate = isEditing ? draft : field.text.wrappedValue
        guard let pretty = JsonField.prettyPrinted(candidate) else {
            validation = JsonField.validate(candidate)
            return
        }
        draft = pretty
        validation = .valid
        isEditing = true
    }
}
