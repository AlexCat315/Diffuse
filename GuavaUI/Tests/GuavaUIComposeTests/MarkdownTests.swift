import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Markdown parsing")
struct MarkdownParsingTests {
    @Test("Inline emphasis, code, strikethrough and links become styled runs")
    func inlineRuns() {
        let blocks = MarkdownParser.blocks("A **bold *both*** `code` ~~gone~~ [site](https://a.b) <br>end")
        guard case .paragraph(let runs) = blocks.first else { Issue.record("expected a paragraph"); return }
        #expect(runs.contains(RichTextRun("bold ", traits: .bold)))
        #expect(runs.contains(RichTextRun("both", traits: [.bold, .italic])))
        #expect(runs.contains(RichTextRun("code", traits: .code)))
        #expect(runs.contains(RichTextRun("gone", traits: .strikethrough)))
        #expect(runs.contains(RichTextRun("site", link: "https://a.b")))
        // Adjacent plain text is merged rather than shaped piece by piece.
        #expect(!zip(runs, runs.dropFirst()).contains { $0.traits == $1.traits && $0.link == $1.link })
    }

    @Test("Soft breaks join lines; hard breaks keep them")
    func breaks() {
        guard case .paragraph(let soft) = MarkdownParser.blocks("one\ntwo").first,
              case .paragraph(let hard) = MarkdownParser.blocks("one  \ntwo").first else {
            Issue.record("expected paragraphs"); return
        }
        #expect(soft.map(\.text).joined() == "one two")
        #expect(hard.map(\.text).joined() == "one\ntwo")
    }

    @Test("Block structure: headings, quotes, nested and task lists, code, rules and tables")
    func blocks() {
        let source = """
        # Title
        ## Sub

        > quoted

        3. three
        4. four
           - nested

        - [x] done
        - [ ] todo

        ```swift
        let x = 1
        ```

        ---

        | A | B |
        | :-: | --: |
        | 1 | 2 |
        """
        let blocks = MarkdownParser.blocks(source)
        #expect(blocks.count == 8)
        #expect(blocks[0] == .heading(level: 1, [RichTextRun("Title")]))
        #expect(blocks[1] == .heading(level: 2, [RichTextRun("Sub")]))
        #expect(blocks[2] == .quote([.paragraph([RichTextRun("quoted")])]))
        guard case .list(let ordered) = blocks[3], case .list(let tasks) = blocks[4],
              case .table(let table) = blocks[7] else { Issue.record("unexpected block kinds"); return }
        #expect(ordered.start == 3 && ordered.items.count == 2)
        #expect(ordered.items[1].blocks.count == 2)
        if case .list(let nested) = ordered.items[1].blocks[1] { #expect(nested.start == nil) }
        else { Issue.record("expected a nested list") }
        #expect(tasks.items.map(\.isChecked) == [true, false])
        #expect(blocks[5] == .code(language: "swift", text: "let x = 1"))
        #expect(blocks[6] == .rule)
        #expect(table.alignments == [.center, .trailing])
        #expect(table.header.count == 2 && table.rows == [[[RichTextRun("1")], [RichTextRun("2")]]])
    }

    @Test("Equal sources reuse one parse")
    func cached() {
        let source = "cache *me* \(Int.random(in: 0..<1_000_000))"
        #expect(MarkdownParser.blocks(source) == MarkdownParser.blocks(source))
    }
}

@Suite("Markdown rendering", .serialized)
struct MarkdownRenderingTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }

    private func render(_ source: String, width: Float = 360, _ check: (Node) -> Void) {
        GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: MarkdownView(source))
            graph.computeLayout(width: width, height: 2000)
            check(graph.tree.root!)
            graph.install(root: EmptyView())
        }
    }

    @Test("Headings are exposed as headings and are larger than body text")
    func headings() {
        render("# Big\n\nbody") { root in
            let heading = nodes(root).first { $0.accessibility?.role == .heading }
            let body = nodes(root).first { $0.accessibility?.label == "body" }
            #expect(heading?.accessibility?.label == "Big")
            #expect((heading?.frame.height ?? 0) > (body?.frame.height ?? 0))
        }
    }

    @Test("A long code line keeps its width and scrolls instead of wrapping")
    func codeScrolls() {
        let line = String(repeating: "x", count: 200)
        render("```\n\(line)\n```", width: 320) { root in
            let code = nodes(root).first { $0.accessibility?.label == line }
            #expect(code != nil)
            #expect((code?.frame.width ?? 0) > 320)
            #expect((code?.frame.height ?? 100) < 40)
            #expect(nodes(root).contains { $0.accessibility?.role == .scrollArea })
        }
    }

    @Test("Paragraphs wrap to the container and task items expose a read-only checkbox")
    func wrapsAndTasks() {
        render("word word word word word word word word word word word word\n\n- [x] done", width: 200) { root in
            let paragraph = nodes(root).first { $0.accessibility?.label.hasPrefix("word") == true }
            #expect((paragraph?.frame.width ?? 999) <= 200)
            #expect((paragraph?.frame.height ?? 0) > 20)
            let box = nodes(root).first { $0.accessibility?.role == .checkbox }
            #expect(box?.accessibility?.state.isSelected == true)
            #expect(box?.accessibility?.state.isReadOnly == true)
        }
    }

    @Test("Table columns fit their widest cell and every row shares its height")
    func tableColumns() {
        render("| A | Longer header |\n| --- | --- |\n| 1 | 2 |", width: 600) { root in
            let cells = nodes(root).filter { ["A", "Longer header", "1", "2"].contains($0.accessibility?.label ?? "") }
            #expect(cells.count == 4)
            let a = cells.first { $0.accessibility?.label == "A" }!.absoluteFrame
            let one = cells.first { $0.accessibility?.label == "1" }!.absoluteFrame
            let header = cells.first { $0.accessibility?.label == "Longer header" }!.absoluteFrame
            #expect(abs(a.minX - one.minX) < 0.5)
            #expect(header.minX > a.maxX)
            #expect(one.minY > a.maxY - 0.5)
        }
    }
}
