import GuavaUI

struct MarkdownStory: View {
    @State private var lastOpened = "none"
    @State private var draft = TextBuffer(MarkdownStory.editable)

    static let document = """
    # Release notes

    GuavaUI **0.10** brings *rich text* to every surface. Paragraphs mix `inline code`, \
    ~~old names~~ and [links](https://github.com/swiftlang/swift-markdown) in one flow, and \
    long lines wrap at the container width.

    ## What changed

    1. Markdown parsing through swift-markdown (CommonMark + GFM)
    2. Code blocks keep their lines and scroll sideways
    3. Tables size columns to their content

    - Bullets nest
      - with a lighter marker
        - three levels deep
    - [x] Task lists show their state
    - [ ] Unchecked items stay muted

    > Quotes keep a rule on the leading edge and a quieter colour,
    > even across **several** lines.

    ```swift
    let view = MarkdownView(notes) { destination in router.open(destination) }
    ```

    | Block | Phone | Desktop |
    | :--- | :---: | ---: |
    | Paragraph | wraps | wraps |
    | Code | scrolls | scrolls |
    | Table | scrolls | fits |

    ---

    中文段落同样按字断行：**粗体**、*斜体* 与 `代码` 混排。
    """

    static let compact = """
    ### Install
    Run `guava build` then open the **Gallery**:
    ```sh
    guava run GuavaUI/Examples --mac --devtools -- --component markdown --width 390
    ```
    """

    static let editable = """
    ### Live preview
    Edit the source above; the **preview** updates as you type. See the [guide](guide://markdown).
    - one
    - two
    """

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Document", "Headings, inline styles, nested and task lists, quotes, a scrolling code block, a table and a rule — rendered from one Markdown string.") {
                MarkdownView(Self.document) { lastOpened = $0 }
                Text("Last opened: \(lastOpened)").font(.caption).foregroundColor(.onSurfaceMuted)
            }
            StorySection("Live preview", "The source is parsed once per change; equal sources reuse the parsed document.") {
                ResizableTextArea("Markdown source", text: $draft, minHeight: 110, maxHeight: 260)
                MarkdownView(draft.stringValue) { lastOpened = $0 }
            }
        }
    }
}
