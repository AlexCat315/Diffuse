import Foundation
import GuavaUIRuntime

public struct TimeFieldOptions {
    public var showSeconds = false
    public var isEnabled = true
    public var minuteStep = 1
    public var minimum = TimeOfDay()
    public var maximum = TimeOfDay(hour: 23, minute: 59, second: 59)
    public init() {}
    mutating func validate() { minuteStep = min(60, max(1, minuteStep)); maximum = max(minimum, maximum) }
}
private struct TimeFieldSession { var draft = TextBuffer.empty; var isEditing = false; var changed = false; var error = "" }

/// An editable draft commits on Return/blur. Invalid text never overwrites the bound time.
public struct TimeField: View {
    public let value: Binding<TimeOfDay?>
    public var options = TimeFieldOptions()
    @State private var session = TimeFieldSession()
    public init(value: Binding<TimeOfDay?>, configure: (inout TimeFieldOptions) -> Void = { _ in }) {
        self.value = value; configure(&options); options.validate()
    }
    public var body: some View {
        let committed = TextBuffer(value.wrappedValue?.formatted(showSeconds: options.showSeconds) ?? "")
        return Column(alignment: .leading, spacing: 4) {
            TextField(options.showSeconds ? "HH:MM:SS" : "HH:MM", text: Binding(get: {
                session.isEditing ? session.draft : committed
            }, set: { session.draft = $0; session.changed = true })) { input in
                input.behavior.disabled = !options.isEnabled
                input.events.onFocus = {
                    session.draft = committed
                    session.isEditing = true; session.changed = false
                }
                input.events.onBlur = { commit(); session.isEditing = false }
                input.events.onSubmit = commit
                input.events.onCancel = { session.error = ""; session.changed = false; session.draft = committed }
                input.events.onKeyDown = { event in
                    guard event.scancode == Scancode.arrowUp || event.scancode == Scancode.arrowDown else { return false }
                    let current = value.wrappedValue ?? options.minimum
                    let delta = (event.scancode == Scancode.arrowUp ? 1 : -1) * (event.modifiers.isDisjoint(with: .shift) ? options.minuteStep * 60 : 3600)
                    let seconds = min(options.maximum.seconds, max(options.minimum.seconds, current.seconds + delta))
                    let next = TimeOfDay(hour: seconds / 3600, minute: seconds / 60 % 60, second: seconds % 60)
                    value.wrappedValue = next; session.draft = TextBuffer(next.formatted(showSeconds: options.showSeconds)); session.changed = false; session.error = ""
                    return true
                }
            }.accessibility { $0.label = "Time"; $0.state.isInvalid = !session.error.isEmpty }
            if !session.error.isEmpty { Text(session.error).font(.caption).foregroundColor(.error) }
        }
    }
    private func commit() {
        guard session.changed else { return }
        if session.draft.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.wrappedValue = nil; session.error = ""; session.changed = false; return }
        guard let next = TimeOfDay.parse(session.draft.stringValue, showSeconds: options.showSeconds), next >= options.minimum, next <= options.maximum else {
            session.error = "Enter a valid time from \(options.minimum.formatted(showSeconds: options.showSeconds)) to \(options.maximum.formatted(showSeconds: options.showSeconds))."; return
        }
        value.wrappedValue = next; session.error = ""; session.changed = false
    }
}
