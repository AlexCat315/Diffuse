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
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.arrowLeft, modifiers: [.alt])) == .back)
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.z, modifiers: [.gui])) == .undo)
        #expect(ScriptSemanticCommand.matching(key(ComposeScancode.z, modifiers: [.gui, .shift])) == .redo)
    }

    @Test("navigation back stack retains file identity and exact UTF-16 position")
    func navigationStack() {
        var history = ScriptSemanticNavigation()
        let first = ScriptSemanticLocation(scriptID: "one", fileURL: nil, position: .init(line: 2, character: 8))
        let second = ScriptSemanticLocation(scriptID: nil, fileURL: URL(fileURLWithPath: "/SDK/Runtime.swift"), position: .init(line: 10, character: 4))
        history.record(first); history.record(first); history.record(second)
        #expect(history.previous.count == 2)
        #expect(history.back() == second)
        #expect(history.back() == first)
        #expect(history.back() == nil)
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
