import Foundation
import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Testing
@testable import EditorUI

@Suite("Document editing presentations", .serialized)
@MainActor
struct DocumentEditingTests {
    @Test("Narrow document panels expose files and the full-width Markdown editing surface")
    func compactPanel() throws {
        try WorkbenchUITestSupport.withEnvironment { _, _ in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data("# Readme".utf8).write(to: directory.appendingPathComponent("README.md"))
            let model = EditorDocumentWorkspace(root: directory)
            let context = PlatformInputContext()
            try context.withCurrent {
                var surface = UIEnvironment(); surface.input = [.touch]
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: DocumentsPanel(model: model).frame(width: 390, height: 700).surfaceEnvironment(surface))
                defer { graph.install(root: EmptyView()) }
                func settle() {
                    for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: 390, height: 700) }
                }
                settle()
                let file = try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) {
                    $0.acceptsSubtreeInput && $0.accessibility?.role == .button && $0.accessibility?.label == "README.md"
                })
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                                capture: context.pointerCapture, focusChain: context.focusChain)
                let frame = file.absoluteFrame
                let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
                dispatcher.dispatch(.mouseButtonDown(event)); dispatcher.dispatch(.mouseButtonUp(event)); settle()
                let source = try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) {
                    $0.acceptsSubtreeInput && $0.accessibility?.role == .textField && $0.accessibility?.label == L("Source code")
                })
                #expect(model.selectedPath == "README.md")
                #expect(source.frame.width > 340)
                #expect(source.frame.height > 400)
                #expect(source.absoluteFrame.maxX <= 390)
            }
        }
    }

    @Test("Markdown preview and plain code share the workspace editing and saving lifecycle")
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
                    graph.install(root: DocumentEditingSurface(model: model, path: path).frame(width: 720, height: 480))
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
