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
    public var apply: String
    public var cancel: String
    public var done: String { get { apply } set { apply = newValue } }

    public init(format: String = "Format", revert: String = "Revert",
                valid: String = "Valid JSON", empty: String = "Empty saves as {}",
                expand: String = "Expand JSON Editor", apply: String = "Apply", cancel: String = "Cancel",
                done: String? = nil) {
        self.format = format
        self.revert = revert
        self.valid = valid
        self.empty = empty
        self.expand = expand
        self.apply = done ?? apply
        self.cancel = cancel
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
    @State private var draft = ""
    @State private var hasDraft = false
    @State private var baseline = ""
    @State private var isExpanded = false
    @State private var expandedDraft = ""
    @State private var history = TextEditHistory()
    @State private var expandedHistory = TextEditHistory()

    init(field: JsonField) {
        self.field = field
        _baseline = State(wrappedValue: field.text.wrappedValue)
    }

    private var currentText: String { hasDraft ? draft : field.text.wrappedValue }
    private var validation: JsonFieldValidation { JsonField.validate(currentText) }
    private var draftBinding: Binding<String> {
        Binding(get: { currentText }, set: { value in
            if !hasDraft { baseline = field.text.wrappedValue }
            draft = value
            hasDraft = true
        })
    }

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 4) {
            Row(alignment: .center, spacing: 2) {
                Text("JSON").font(.caption).foregroundColor(.onSurfaceMuted)
                if validation.isAcceptable {
                    Icon(UICommonIcons.checkmark, size: 9, color: .success)
                }
                Spacer(minLength: 0)
                Button(icon: .resource(UICommonIcons.format), size: 12,
                       isEnabled: field.isEnabled && validation.isAcceptable,
                       tooltip: field.labels.format, action: formatDraft)
                    .buttonStyle(.ghost).controlSize(.small)
                Button(icon: .resource(UICommonIcons.reset), size: 12,
                       isEnabled: field.isEnabled && currentText != baseline,
                       tooltip: field.labels.revert, action: revertDraft)
                    .buttonStyle(.ghost).controlSize(.small)
                Button(icon: .resource(UICommonIcons.expand), size: 12,
                       isEnabled: field.isEnabled, tooltip: field.labels.expand, action: {
                    expandedDraft = currentText
                    expandedHistory = TextEditHistory()
                    isExpanded = true
                })
                    .buttonStyle(.ghost).controlSize(.small)
                    .debugName("json-expand")
            }
            ResizableTextArea(field.placeholder, text: draftBinding, minHeight: field.minHeight,
                              disabled: !field.isEnabled, editHistory: history, onSubmit: { _ = commitDraft() },
                              onFocus: beginEditing,
                              onBlur: { if !isExpanded { _ = commitDraft() } })
                .border(validation.isAcceptable ? .border : .error, width: 1)
                .cornerRadius(4)
                .clipped()
                .debugName("json-inline-editor")
            if case let .invalid(message) = validation {
                Text(message, lineLimit: 2).font(.caption).foregroundColor(.error)
            }
            Modal(isPresented: $isExpanded) {
                expandedEditor
            }
        }
        .frame(minWidth: 0)
    }

    private var expandedEditor: some View {
        let result = JsonField.validate(expandedDraft)
        return Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Row(alignment: .center, spacing: 6) {
                Text(field.labels.expand).font(.bodyStrong)
                Spacer(minLength: 0)
                Button(icon: .resource(UICommonIcons.format), size: 14,
                       isEnabled: result.isAcceptable, tooltip: field.labels.format, action: {
                    if let pretty = JsonField.prettyPrinted(expandedDraft) {
                        recordReplacement(before: expandedDraft, after: pretty, in: expandedHistory)
                        expandedDraft = pretty
                    }
                }).buttonStyle(.ghost)
                Button(icon: .resource(UICommonIcons.close), size: 12,
                       tooltip: field.labels.cancel, action: { isExpanded = false }).buttonStyle(.ghost)
            }
            .padding(horizontal: 14, vertical: 8)
            Divider()
            TextField(field.placeholder, text: $expandedDraft, axis: .vertical,
                      maxVisibleLines: 128, showsLineNumbers: true, indentationWidth: 2, editHistory: expandedHistory,
                      onSubmit: applyExpandedDraft, onCancel: { isExpanded = false })
                .font(.mono)
                .frame(minHeight: 0)
                .padding(8)
                .flex(1, shrink: 1, basis: 0)
            Divider()
            Row(alignment: .center, spacing: 8) {
                if case let .invalid(message) = result {
                    Text(message, lineLimit: 2).font(.caption).foregroundColor(.error).flex(1, shrink: 1, basis: 0)
                } else {
                    Icon(UICommonIcons.checkmark, size: 11, color: .success)
                    Text(field.labels.valid).font(.caption).foregroundColor(.onSurfaceMuted)
                }
                Spacer(minLength: 0)
                Button(field.labels.cancel, action: { isExpanded = false }).buttonStyle(.ghost)
                Button(field.labels.apply, isEnabled: result.isAcceptable, action: applyExpandedDraft)
                    .buttonStyle(.primary).debugName("json-apply")
            }
            .padding(horizontal: 14, vertical: 10)
        }
        .background(.surfaceFloating).border(.border, width: 1).cornerRadius(10).clipped()
        .flex(1, shrink: 1, basis: 0)
        .debugName("json-expanded-editor")
    }

    private func beginEditing() {
        guard !hasDraft else { return }
        baseline = field.text.wrappedValue
        draft = field.text.wrappedValue.isEmpty ? "{}" : field.text.wrappedValue
        hasDraft = true
    }

    @discardableResult
    private func commitDraft() -> Bool {
        guard JsonField.validate(currentText).isAcceptable else { return false }
        let normalized = JsonField.normalizedCommitText(currentText)
        if field.text.wrappedValue != normalized {
            field.text.wrappedValue = normalized
            field.onCommit?(normalized)
        }
        draft = normalized
        // Keep the edit baseline available to the revert toolbar action.
        hasDraft = false
        return true
    }

    private func applyExpandedDraft() {
        guard JsonField.validate(expandedDraft).isAcceptable else { return }
        draftBinding.wrappedValue = expandedDraft
        if commitDraft() { isExpanded = false }
    }
    private func revertDraft() {
        recordReplacement(before: currentText, after: baseline, in: history)
        draft = baseline
        hasDraft = true
        _ = commitDraft()
    }
    private func formatDraft() {
        if let pretty = JsonField.prettyPrinted(currentText) {
            recordReplacement(before: currentText, after: pretty, in: history)
            draftBinding.wrappedValue = pretty
        }
    }
    private func recordReplacement(before: String, after: String, in history: TextEditHistory) {
        history.synchronize(before)
        history.record(before: .init(text: before, cursor: before.count),
                       after: .init(text: after, cursor: after.count), kind: .atomic,
                       time: ProcessInfo.processInfo.systemUptime)
    }
}
