import GuavaUIRuntime

/// An editable Markdown source and its native live preview. Give the editor a
/// bounded height. Below 600 points of allocated width, retained tabs replace
/// the split; switching tabs or resizing preserves editing and scrolling state.
/// File access belongs to the caller, just as with `TextField`.
public struct MarkdownEditor: View {
    private let text: Binding<TextBuffer>
    private let sourceTitle: String
    private let previewTitle: String
    private let sourceFont: Font
    private let sourceLineHeight: Float
    private let onOpenLink: ((String) -> Void)?
    @State private var fraction: Float = 0.5
    @State private var preview = MarkdownPreviewSource()

    /// Titles also name the source field and preview region for accessibility.
    /// The source font lets a host match its other code editors.
    public init(text: Binding<TextBuffer>, sourceTitle: String, previewTitle: String,
                sourceFont: Font = .monospaced(size: 15), sourceLineHeight: Float = 24,
                onOpenLink: ((String) -> Void)? = nil) {
        self.text = text
        self.sourceTitle = sourceTitle
        self.previewTitle = previewTitle
        self.sourceFont = sourceFont
        self.sourceLineHeight = sourceLineHeight
        self.onOpenLink = onOpenLink
    }

    public var body: some View {
        // An even pointer grab area keeps the initial equal panes on whole
        // points in RTL as well. Touch still receives the shared 44pt target.
        SplitView(.horizontal, fraction: $fraction, dividerThickness: 8,
                  constraints: .init(minimumFirst: 240, minimumSecond: 240),
                  compact: .init(firstTitle: sourceTitle, secondTitle: previewTitle)) {
            TextField(sourceTitle, text: text) {
                $0.layout.axis = .vertical
                $0.layout.wrapsLines = true
                $0.codeEditing.indentationWidth = 2
            }
            .textFieldStyle(.editor)
            .font(sourceFont).lineHeight(sourceLineHeight)
            .frame(minWidth: 0, minHeight: 0)
        } second: {
            ScrollView(.vertical, scrollbarGutter: .stable) {
                MarkdownView(preview.string(for: text.wrappedValue), onOpenLink: onOpenLink)
                    .padding(16).flex(0, shrink: 0).frame(minWidth: 0)
            }.accessibility { $0.label = previewTitle }
        }
    }
}

/// Materialize the Rope only when its revision changes, not on focus, theme,
/// divider or scroll updates. This cache never writes to the authored buffer.
private final class MarkdownPreviewSource {
    private var buffer: TextBuffer?
    private var source = ""

    func string(for buffer: TextBuffer) -> String {
        if self.buffer != buffer {
            self.buffer = buffer
            source = buffer.stringValue
        }
        return source
    }
}
