import Foundation
import Testing
@testable import EditorCore
import GuavaUICompose
import GuavaUIRuntime
@testable import EditorUI

@Suite("Swift semantic editor commands")
struct ScriptSemanticCommandsTests {
    private func key(_ code: UInt32, modifiers: KeyModifiers = []) -> KeyEvent {
        KeyEvent(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)
    }

    @Test("language shortcuts do not replace normal completion or unrelated typing")
    func keyboardCommands() {
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.f12)) == .definition)
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.f12, modifiers: [.shift])) == .references)
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.f2)) == .rename)
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.period, modifiers: [.gui])) == .codeActions)
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.space, modifiers: [.ctrl, .shift])) == .signature)
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.space, modifiers: [.ctrl])) == nil)
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.leftBracket, modifiers: [.gui])) == .back)
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.rightBracket, modifiers: [.gui])) == .forward)
        // Option-arrows stay word movement in the text.
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.arrowLeft, modifiers: [.alt])) == nil)
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.b, modifiers: [.gui, .alt])) == .implementations)
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.b, modifiers: [.gui])) == nil)
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.u, modifiers: [.gui])) == .supertypes)
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.z, modifiers: [.gui])) == .undo)
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.z, modifiers: [.gui, .shift])) == .redo)
    }

    @Test("symbol icons distinguish Swift types, protocols, functions and properties")
    func symbolIcons() {
        #expect(ScriptSymbolIcon(kind: 5) == .type)
        #expect(ScriptSymbolIcon(kind: 23) == .type)
        #expect(ScriptSymbolIcon(kind: 11) == .interface)
        for kind in [6, 9, 12] { #expect(ScriptSymbolIcon(kind: kind) == .function) }
        for kind in [7, 8] { #expect(ScriptSymbolIcon(kind: kind) == .property) }
        #expect(ScriptSymbolIcon(kind: 10) == .enumeration)
        #expect(ScriptSymbolIcon(kind: 13) == .variable)
        #expect(ScriptSymbolIcon(kind: 999) == .symbol)
        #expect(Set([5, 11, 12, 7].map { ScriptSymbolIcon(kind: $0).resource }).count == 4)
    }

    @Test("navigation icons dispatch their commands and respect disabled back navigation", arguments: [true, false])
    @MainActor
    func navigationIcons(canGoBack: Bool) throws {
        try WorkbenchUITestSupport.withEnvironment { registry, focus in
            var commands: [ScriptSemanticCommand] = []
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: ScriptNavigationButtons(commands: [.back, .definition, .references], canPerform: { $0 != .back || canGoBack }, perform: { commands.append($0) })
                .theme(EditorVisualTheme.make(dark: true)))
            graph.recomposer.commitAll()
            graph.computeLayout(width: 200, height: 40)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry, capture: PointerCapture(), focusChain: focus)
            for name in ["back", "definition", "references"] {
                let node = try WorkbenchUITestSupport.named("script-navigation-\(name)", in: graph.tree.root)
                let frame = node.absoluteFrame
                #expect(frame.size.width >= 24 && frame.size.height >= 24)
                let click = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
                dispatcher.dispatch(.mouseButtonDown(click))
                dispatcher.dispatch(.mouseButtonUp(click))
            }
            #expect(commands == (canGoBack ? [.back, .definition, .references] : [.definition, .references]))
        }
    }

    @Test("navigation history keeps file identity, exact UTF-16 positions and a forward stack")
    func navigationStack() {
        var history = ScriptSemanticNavigation()
        let first = ScriptSemanticLocation(scriptID: "one", fileURL: nil, position: .init(line: 2, character: 8))
        let second = ScriptSemanticLocation(scriptID: nil, fileURL: URL(fileURLWithPath: "/SDK/Runtime.swift"), position: .init(line: 10, character: 4))
        let here = ScriptSemanticLocation(scriptID: "two", fileURL: nil, position: .init(line: 0, character: 0))
        history.record(first); history.record(first); history.record(second)
        #expect(history.previous.count == 2)
        #expect(history.back(from: here) == second)
        #expect(history.back(from: second) == first)
        #expect(history.back(from: first) == nil)
        #expect(history.forward(from: first) == second)
        #expect(history.forward(from: second) == here)
        #expect(history.forward(from: here) == nil)
        // A new jump abandons the forward path, like a browser.
        _ = history.back(from: here)
        history.record(first)
        #expect(history.next.isEmpty)
    }

    @Test("resolved actions with disabled reasons cannot apply their returned edits")
    func disabledResolvedAction() throws {
        let uri = "file:///shadow/Script.swift"
        let context = ScriptSemanticContext(documents: [uri: .init(scriptID: "one", revision: 0, version: 1)])
        let edit: [String: Any] = ["changes": [uri: [["range": ["start": ["line": 0, "character": 0],
                                                                 "end": ["line": 0, "character": 0]], "newText": "replacement"]]]]
        let disabled = try ScriptEditingReplies.codeAction(["title": "Fix", "edit": edit,
                                                            "disabled": ["reason": "The declaration is no longer available"]], context: context)
        #expect(disabled.edit?.isEmpty == false)
        #expect(throws: ScriptLanguageEditError.disabledAction("The declaration is no longer available")) {
            try ScriptSemanticSession.applicableEdit(disabled)
        }
        let command = try ScriptEditingReplies.codeAction(["title": "Fix", "edit": edit,
                                                           "command": ["command": "swift.refactor"]], context: context)
        #expect(throws: ScriptLanguageEditError.disabledAction(ScriptLanguageEditError.unsupportedCommand.localizedDescription)) {
            try ScriptSemanticSession.applicableEdit(command)
        }
        let enabled = try ScriptEditingReplies.codeAction(["title": "Fix", "edit": edit], context: context)
        #expect(try ScriptSemanticSession.applicableEdit(enabled)?.documents.first?.edits.first?.text == "replacement")
    }
}
