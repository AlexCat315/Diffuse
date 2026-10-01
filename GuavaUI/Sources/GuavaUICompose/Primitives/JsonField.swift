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
    public var expand: String
    public var done: String

    public init(format: String = "Format", revert: String = "Revert",
                valid: String = "Valid JSON", empty: String = "Empty saves as {}",
                expand: String = "Expand Editor", done: String = "Done") {
        self.format = format
        self.revert = revert
        self.valid = valid
        self.empty = empty
        self.expand = expand
        self.done = done
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
    @State var expanded = false
    @State var history = TextEditHistory()

    private var currentValidation: JsonFieldValidation {
        hasDraft ? validation : JsonField.validate(field.text.wrappedValue)
    }
    private var value: Binding<String> {
        Binding(get: { hasDraft ? draft : field.text.wrappedValue }, set: { next in
            draft = next; hasDraft = true; validation = JsonField.validate(next)
        })
    }
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 4) {
            toolbar(showsExpand: true)
            ResizableEditor(initialHeight: max(120, field.minHeight), minHeight: 120, maxHeight: 520) {
                editor
            }
            .background(.surfaceSunken).cornerRadius(4).border(borderColor, width: 1).clipped()
            errorMessage
            Modal(isPresented: $expanded, width: 780, height: 600) {
                Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    toolbar(showsExpand: false)
                    editor.flex(1, shrink: 1).frame(minHeight: 0)
                    errorMessage
                }.padding(12)
            }
        }
    }
    private var editor: some View {
        TextField(field.placeholder, text: value, axis: .vertical, maxVisibleLines: 200,
                  showsLineNumbers: true, indentationWidth: 2, editHistory: history,
                  disabled: !field.isEnabled, onSubmit: commitDraft,
                  onFocus: {
                    if !hasDraft {
                        draft = field.text.wrappedValue.isEmpty ? "{}" : field.text.wrappedValue
                        validation = JsonField.validate(draft); hasDraft = true
                    }
                  }, onBlur: commitDraft)
            .font(.mono)
            .textFieldStyle(_JsonEditorStyle())
    }
    private func toolbar(showsExpand: Bool) -> some View {
        Row(alignment: .center, spacing: 4) {
            Text("JSON").font(.caption).foregroundColor(.onSurfaceMuted)
            if currentValidation.isAcceptable {
                Icon(UICommonIcons.checkmark, size: 10, color: .onSurfaceMuted)
            }
            Spacer(minLength: 0)
            Button(icon: .resource(UICommonIcons.formatjson), size: 12,
                   isEnabled: field.isEnabled && currentValidation.isAcceptable,
                   tooltip: field.labels.format, action: formatDraft).buttonStyle(.ghost).controlSize(.small)
            Button(icon: .resource(UICommonIcons.revert), size: 12,
                   isEnabled: field.isEnabled && hasDraft, tooltip: field.labels.revert, action: revertDraft)
                .buttonStyle(.ghost).controlSize(.small)
            if showsExpand {
                Button(icon: .resource(UICommonIcons.expand), size: 12, tooltip: field.labels.expand) { expanded = true }
                    .buttonStyle(.ghost).controlSize(.small)
            } else {
                Button(field.labels.done) { expanded = false }.buttonStyle(.primary).controlSize(.small)
            }
        }.frame(height: 26)
    }
    @ViewBuilder private var errorMessage: some View {
        if case .invalid(let message) = currentValidation {
            Text(message, lineLimit: 2).font(.caption).foregroundColor(.error)
        }
    }
    private var borderColor: SemanticColorRef { currentValidation.isAcceptable ? .border : .error }
    private func revertDraft() {
        let before = value.wrappedValue
        draft = field.text.wrappedValue; validation = JsonField.validate(draft); hasDraft = false
        recordReplacement(before: before, after: draft)
    }
    private func recordReplacement(before: String, after: String) {
        history.synchronize(before)
        history.record(before: .init(text: before, cursor: before.count), after: .init(text: after, cursor: after.count),
                       kind: .atomic, time: ProcessInfo.processInfo.systemUptime)
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
        recordReplacement(before: candidate, after: pretty)
        draft = pretty
        validation = .valid
        hasDraft = true
    }
}

private struct _JsonEditorStyle: TextFieldStyle {
    func makeBody(configuration: TextFieldStyleConfiguration) -> some View {
        configuration.content.background(.surfaceSunken)
            .border(configuration.isFocused ? .focusRing : .border, width: 1).cornerRadius(4)
    }
}
