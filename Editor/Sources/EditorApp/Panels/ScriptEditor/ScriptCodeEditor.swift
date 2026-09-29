import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime

/// The Swift script editing surface.
///
/// Owns exactly one thing: turning text-field signals into requests the panel
/// can act on. It holds no language-service state — that lives in the panel so
/// switching scripts cannot leave a stale popup behind.
struct ScriptCodeEditor: View {
    let source: Binding<String>
    let hover: Binding<ScriptEditorHoverPresentation>
    let caretLabel: Binding<String>
    let onChange: (String) -> Void
    /// Pointer rests on a character worth documenting.
    let onHover: (TextFieldHoverAnchor) -> Void
    /// Pointer left the field; any pending popup must go away.
    let onHoverEnd: () -> Void

    var body: some View {
        let text = source.wrappedValue
        let highlighter = SwiftSyntaxHighlighter(text)
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            TextField(
                "",
                text: source,
                axis: .vertical,
                maxVisibleLines: 48,
                showsLineNumbers: true,
                lineNumberColor: Color(r: 0.45, g: 0.49, b: 0.55),
                syntaxColorAtUTF8Offset: { _, offset in highlighter.color(atUTF8Offset: offset) },
                onChange: onChange,
                onHoverChange: { anchor in handleHover(anchor) },
                onCaretChange: { state in handleCaret(state, in: text) },
                textColor: Color(r: 0.86, g: 0.89, b: 0.92)
            )
            .font(.mono)
            .frame(minHeight: 360, maxHeight: .infinity)
            .padding(horizontal: 8, vertical: 8)
            .background(Color(r: 0.105, g: 0.12, b: 0.145))
            .flex(1, shrink: 1)

            // Contributes no layout; the popup is painted through the tooltip
            // pass so the editor's own clipping never trims it.
            ScriptHoverOverlay(presentation: hover.wrappedValue)

            Divider()
            editorFooter(lineCount: Self.countLines(in: text))
        }
        .cornerRadius(4)
        .border(.divider, width: 1)
        .clipped()
    }

    private func editorFooter(lineCount: Int) -> some View {
        Row(alignment: .center, spacing: 12) {
            Text("Swift")
            Text("UTF-8")
            Text(L("\(lineCount) lines"))
            Text(caretLabel.wrappedValue)
                .foregroundColor(.onSurfaceMuted)
            Spacer(minLength: 0)
            Text("GameScript")
        }
        .font(.caption)
        .foregroundColor(.onSurfaceMuted)
        .padding(horizontal: 10, vertical: 5)
        .background(.surface)
    }

    private func handleHover(_ anchor: TextFieldHoverAnchor?) {
        guard let anchor else {
            hover.wrappedValue = .hidden
            onHoverEnd()
            return
        }
        onHover(anchor)
    }

    private func handleCaret(_ state: TextFieldCaretState, in text: String) {
        let position = ScriptSourceCoordinates.position(in: text, atCharacterIndex: state.caretIndex)
        caretLabel.wrappedValue = "Ln \(position.line + 1), Col \(position.character + 1)"
    }

    static func countLines(in text: String) -> Int {
        max(1, text.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        })
    }
}
