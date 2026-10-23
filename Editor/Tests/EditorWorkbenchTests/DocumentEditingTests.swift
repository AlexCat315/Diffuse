import Foundation
import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Testing
@testable import EditorUI

@Suite("Document editing presentations", .serialized)
@MainActor
struct DocumentEditingTests {
    @Test("The file tree opens documents into editor tabs, and closing keeps unsaved work")
    func filesAndTabs() throws {
        try WorkbenchUITestSupport.withEnvironment { _, _ in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data("# Readme".utf8).write(to: directory.appendingPathComponent("README.md"))
            try Data("let x = 1\n".utf8).write(to: directory.appendingPathComponent("Scripts/Game.swift"))
            let model = EditorDocumentWorkspace(root: directory)
            let context = PlatformInputContext()
            try context.withCurrent {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: Row(alignment: .top, spacing: 0) {
                    DocumentFilesPanel(model: model).frame(width: 240, height: 600)
                    DocumentsPanel(model: model).frame(width: 660, height: 600)
                })
                defer { graph.install(root: EmptyView()) }
                func settle() {
                    for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: 900, height: 600) }
                }
                func named(_ name: String) -> Bool { graph.layoutSnapshot().contains { $0.debugName == name } }
                settle()
                #expect(named("document-empty"))
                #expect(!named("document-tabs"))

                // Top-level folders start expanded, so the script is one click away.
                let label = try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) { node in
                    node.accessibility?.role != .treeItem && node.accessibility?.label == "Game.swift"
                })
                var row: Node? = label
                while let candidate = row, candidate.accessibility?.role != .treeItem { row = candidate.parent }
                // Activation is the selection path a click and VoiceOver both use.
                let activate = try #require(row?.accessibilityActions.activate)
                activate()
                settle()
                #expect(model.selectedPath == "Scripts/Game.swift")
                let source = try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) {
                    $0.acceptsSubtreeInput && $0.accessibility?.role == .textField && $0.accessibility?.label == L("Source code")
                })
                #expect(source.absoluteFrame.minX >= 240)
                #expect(source.frame.width > 500)
                #expect(named("document-path-bar"))

                model.open("README.md"); settle()
                #expect(named("document-tab-README.md") && named("document-tab-Scripts/Game.swift"))

                // Closing the selected tab selects its neighbour instead of an empty pane.
                model.close("README.md"); settle()
                #expect(model.selectedPath == "Scripts/Game.swift")
                #expect(!named("document-tab-README.md"))

                // A modified document refuses a plain close and survives it.
                model.edit("Scripts/Game.swift", text: "let x = 2\n")
                model.close("Scripts/Game.swift"); settle()
                #expect(model.error != nil)
                #expect(model.documents.contains { $0.path == "Scripts/Game.swift" && $0.isDirty })
                model.close("Scripts/Game.swift", discard: true); settle()
                #expect(model.documents.isEmpty)
                #expect(model.selectedPath == nil)
                #expect(named("document-empty"))
            }
        }
    }

    @Test("File tree folders come first and default expansion reveals the selected file")
    func fileTree() {
        let tree = DocumentFileNode.tree(["b.txt", "Scripts/Game.swift", "a.md", "Docs/Guide/intro.md"])
        #expect(tree.map(\.name) == ["Docs", "Scripts", "a.md", "b.txt"])
        #expect(tree.first?.children.first?.path == "Docs/Guide")
        let expanded = DocumentFileNode.defaultExpansion(tree, selected: "Docs/Guide/intro.md")
        #expect(expanded == ["Docs", "Scripts", "Docs/Guide"])
        #expect(DocumentFileNode.keys(in: tree)["Docs/Guide/intro.md"]?.path == [0, 0, 0])
        #expect(DocumentKind(path: "Scripts/Game.swift").name == "Swift")
        #expect(DocumentKind(path: "README.MD").isMarkdown)
        #expect(DocumentKind(path: "paper.tex").languageID == "latex")
        #expect(EditorTitleBar.initials(of: "CrystalRush") == "CR")
        #expect(EditorTitleBar.initials(of: "my game") == "MG")
        #expect(EditorTitleBar.initials(of: "demo") == "DE")
    }

    @Test("Markdown and plain code share the workspace editing and saving lifecycle")
    func formats() throws {
        try WorkbenchUITestSupport.withEnvironment { _, _ in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            for ext in ["md", "MARKDOWN", "txt", "swift", "java"] {
                let path = "document.\(ext)"
                let url = directory.appendingPathComponent(path)
                let original = "# Original\r\n\r\n中文 👩🏽‍💻\r\n"
                try Data(original.utf8).write(to: url)
                let model = EditorDocumentWorkspace(root: directory)
                model.open(path)
                let context = PlatformInputContext()
                try context.withCurrent {
                    let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                    graph.install(root: DocumentEditingSurface(model: model, app: nil, path: path, session: DocumentWritingSession()).frame(width: 720, height: 480))
                    defer { graph.install(root: EmptyView()) }
                    func settle() {
                        for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: 720, height: 480) }
                    }
                    func field() throws -> Node {
                        try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) { $0.accessibility?.role == .textField })
                    }
                    let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                                    capture: context.pointerCapture, focusChain: context.focusChain)
                    func key(_ scan: UInt32) {
                        dispatcher.dispatch(.keyDown(.init(scancode: scan, keycode: 0, modifiers: .lgui, isRepeat: false)))
                    }
                    settle()
                    let initialField = try field()
                    let hasPreview = WorkbenchUITestSupport.firstNode(graph.tree.root) { $0.accessibility?.role == .heading } != nil
                    #expect(hasPreview == ["md", "MARKDOWN"].contains(ext))
                    context.focusChain.focus(initialField); key(Scancode.a)
                    dispatcher.dispatch(.textInput("# Edited\r\n\r\n**Preview**\r\n")); settle()
                    #expect(model.hasUnsavedChanges)
                    #expect(model.documents.first?.text == "# Edited\r\n\r\n**Preview**\r\n")
                    model.save(path); settle()
                    #expect(!model.hasUnsavedChanges)
                    #expect(try String(contentsOf: url, encoding: .utf8) == model.documents.first?.text)
                    #expect(try field() === initialField)
                    context.focusChain.focus(initialField); key(Scancode.z); settle()
                    #expect(model.documents.first?.text == original)
                    #expect(model.hasUnsavedChanges)
                    try Data("# External\n".utf8).write(to: url)
                    model.reload(path, discard: true); settle()
                    #expect(!model.hasUnsavedChanges)
                    #expect(model.documents.first?.text == "# External\n")
                    let reloadedField = try field()
                    #expect(reloadedField !== initialField)
                    context.focusChain.focus(reloadedField); key(Scancode.z); settle()
                    #expect(model.documents.first?.text == "# External\n")
                }
            }
        }
    }
}
