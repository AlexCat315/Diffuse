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

public struct JsonFieldLabels: Sendable {
    public var format: String
    public var revert: String
    public var valid: String
    public var empty: String

    public init(format: String = "Format", revert: String = "Revert",
                valid: String = "Valid JSON", empty: String = "Empty saves as {}") {
        self.format = format
        self.revert = revert
        self.valid = valid
        self.empty = empty
    }
}

public struct JsonField: View {
    public let text: Binding<String>
    public let placeholder: String
    public let minHeight: Float
    public let isEnabled: Bool
    public let onCommit: ((String) -> Void)?
    public let labels: JsonFieldLabels

    public init(text: Binding<String>,
                placeholder: String = "{}",
                minHeight: Float = 96,
                isEnabled: Bool = true,
                labels: JsonFieldLabels = JsonFieldLabels(),
                onCommit: ((String) -> Void)? = nil) {
        self.text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
        self.isEnabled = isEnabled
        self.onCommit = onCommit
        self.labels = labels
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
    @State var hasDraft: Bool = false
    @State var validation: JsonFieldValidation = .valid

    var body: some View {
        let currentValidation = hasDraft ? validation : JsonField.validate(field.text.wrappedValue)

        Box(direction: .column, alignItems: .stretch, spacing: 6) {
            TextField(field.placeholder,
                      text: Binding(
                        get: { hasDraft ? draft : field.text.wrappedValue },
                        set: { next in
                            draft = next
                            hasDraft = true
                            validation = JsonField.validate(next)
                        }
                      ),
                      axis: .vertical,
                      showsLineNumbers: true,
                      indentationWidth: 2,
                      disabled: !field.isEnabled,
                      onSubmit: {
                        commitDraft()
                      },
                      onFocus: {
                        if !hasDraft {
                            draft = field.text.wrappedValue.isEmpty ? "{}" : field.text.wrappedValue
                            validation = JsonField.validate(draft)
                            hasDraft = true
                        }
                      },
                      onBlur: {
                        commitDraft()
                      })
                .font(.mono)
                .frame(height: max(96, field.minHeight))
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
                    Text(field.labels.format)
                        .font(.caption)
                        .foregroundColor(.onSurfaceVariant)
                }
                .buttonStyle(.ghost)

                Button(role: .normal,
                       isEnabled: field.isEnabled,
                       action: {
                    draft = field.text.wrappedValue
                    validation = JsonField.validate(draft)
                    hasDraft = false
                }) {
                    Text(field.labels.revert)
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
                Text(field.labels.valid)
                    .font(.caption)
                    .foregroundColor(.success)
            )
        case .empty:
            return AnyView(
                Text(field.labels.empty)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            )
        case let .invalid(message):
            return AnyView(
                Text(message, lineLimit: 2)
                    .font(.caption)
                    .foregroundColor(.error)
                    .clipped()
            )
        }
    }

    private func borderColor(for validation: JsonFieldValidation) -> SemanticColorRef {
        switch validation {
        case .valid, .empty:
            return .border
        case .invalid:
            return .error
        }
    }

    private func commitDraft() {
        let candidate = hasDraft ? draft : field.text.wrappedValue
        let result = JsonField.validate(candidate)
        validation = result
        guard result.isAcceptable else { return }
        let normalized = JsonField.normalizedCommitText(candidate)
        if field.text.wrappedValue != normalized {
            field.text.wrappedValue = normalized
        }
        field.onCommit?(normalized)
        draft = normalized
        hasDraft = false
    }

    private func formatDraft() {
        let candidate = hasDraft ? draft : field.text.wrappedValue
        guard let pretty = JsonField.prettyPrinted(candidate) else {
            validation = JsonField.validate(candidate)
            return
        }
        draft = pretty
        validation = .valid
        hasDraft = true
    }
}
