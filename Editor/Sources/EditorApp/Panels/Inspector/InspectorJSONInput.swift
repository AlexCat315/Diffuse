import GuavaUICompose
import GuavaUIRuntime

/// The authored property stays serialized JSON; the editing surface owns a
/// persistent Rope and materializes it only when JSON validation commits.
struct InspectorJSONInput: View {
    let text: Binding<String>
    let minHeight: Float
    let labels: JsonFieldLabels
    @State private var document = InspectorJSONDocument()
    var body: some View {
        document.synchronize(text.wrappedValue)
        return JsonField(text: Binding(get: { document.buffer }, set: { next in
            document.accept(next); text.wrappedValue = document.serialized
        }), minHeight: minHeight, labels: labels)
    }
}

private final class InspectorJSONDocument {
    var buffer = TextBuffer.empty
    private(set) var serialized = ""
    func synchronize(_ source: String) {
        guard source != serialized else { return }
        serialized = source; buffer = TextBuffer(source)
    }
    func accept(_ next: TextBuffer) {
        buffer = next; serialized = next.stringValue
    }
}
