import Foundation
@testable import PluginRuntime
import Testing

@Suite("Workbench contributions")
struct WorkbenchContributionTests {
    private func manifest(_ contributes: String) -> Data {
        Data("""
        {"id": "test.workbench", "version": 1, "name": "Workbench", "description": "fixture",
         "access": "read", "imports": [], "composable_host_capabilities": [],
         "contributes": \(contributes)}
        """.utf8)
    }

    private func contract(_ functions: String) throws -> WITContract {
        try WITContractParser.parse(Data("""
        package test:workbench;
        interface capabilities {
        \(functions)
        }
        world plugin { export capabilities; }
        """.utf8), grantedImports: [])
    }

    @Test("a panel shows either a host view or content its entry point describes")
    func panelContentIsExclusive() throws {
        let valid = try PluginManifestValidator.decodeAndValidate(manifest("""
            {"guava.ui.panel/v1": [
              {"id": "intent-input", "title": "Harness", "slot": "trailing", "icon": "ai-intent", "view": "agent"},
              {"id": "status", "title": "Status", "entryPoint": "panel"}]}
            """))
        let panels = try valid.contributes.decode(PanelContributionPoint.self)
        #expect(panels.map(\.content) == [.view("agent"), .entryPoint("panel")])

        for invalid in [#"{"id": "x", "title": "X"}"#,
                        #"{"id": "x", "title": "X", "view": "agent", "entryPoint": "panel"}"#,
                        #"{"id": "x", "title": "X", "view": "agent", "slot": "middle"}"#,
                        #"{"id": "x", "title": "X", "view": "Agent View"}"#] {
            #expect(throws: PluginManifestValidationError.invalidContribution(PanelContributionPoint.id)) {
                try PluginManifestValidator.decodeAndValidate(manifest(#"{"guava.ui.panel/v1": [\#(invalid)]}"#))
            }
        }
    }

    @Test("command and panel entry points must take the inputs the host sends")
    func entryPointsMatchTheirInputs() throws {
        let runtime = try contract("""
            record command-input { command: string, arguments: string }
            command: func(input: command-input) -> string;
            record panel-input { view: string, state: string, event: string, context: string }
            panel: func(input: panel-input) -> string;
            """)
        let command = CommandContribution(id: "refresh", title: "Refresh", entryPoint: "command")
        let panel = PanelContribution(id: "status", title: "Status", content: .entryPoint("panel"))
        try CommandContributionPoint.validateRuntime(command, contract: runtime)
        try PanelContributionPoint.validateRuntime(panel, contract: runtime)
        try PanelContributionPoint.validateRuntime(
            PanelContribution(id: "chat", title: "Chat", content: .view("agent")), contract: nil)

        var swapped = command
        swapped.entryPoint = "panel"
        #expect(throws: PluginManifestValidationError.invalidContribution(CommandContributionPoint.id)) {
            try CommandContributionPoint.validateRuntime(swapped, contract: runtime)
        }
        #expect(throws: PluginManifestValidationError.invalidContribution(PanelContributionPoint.id)) {
            try PanelContributionPoint.validateRuntime(panel, contract: nil)
        }
    }

    @Test("command and panel entry points are called by the editor, never offered to the model")
    func entryPointsStayAwayFromAI() throws {
        let manifest = try PluginManifestValidator.decodeAndValidate(manifest("""
            {"guava.command/v1": [{"id": "refresh", "title": "Refresh", "entryPoint": "command", "palette": false}],
             "guava.ui.panel/v1": [{"id": "status", "title": "Status", "entryPoint": "panel"}],
             "guava.ai.tool/v1": [{"entryPoint": "inspect", "title": "Inspect", "description": "Reads the scene."}]}
            """))
        #expect(!manifest.exposesToAI(entryPoint: "command"))
        #expect(!manifest.exposesToAI(entryPoint: "panel"))
        #expect(!manifest.exposesToAI(entryPoint: "undeclared"))
        #expect(manifest.exposesToAI(entryPoint: "inspect"))
        #expect(manifest.aiTool(entryPoint: "inspect")?.description == "Reads the scene.")
        #expect(try manifest.contributes.decode(CommandContributionPoint.self).first?.palette == false)
    }

    @Test("menus, the toolbar, document views and AI context are validated")
    func placementsAndViewsAreValidated() throws {
        let valid = try PluginManifestValidator.decodeAndValidate(manifest("""
            {"guava.ui.menu/v1": [{"command": "refresh", "menu": "run"}],
             "guava.ui.toolbar/v1": [{"command": "refresh", "icon": "toolbar-arrow-path"}],
             "guava.ui.documentView/v1": [{"id": "table", "title": "Table", "extensions": ["csv"], "entryPoint": "document"}],
             "guava.ai.context/v1": [{"id": "summary", "title": "Summary", "entryPoint": "context", "maxBytes": 2048}]}
            """))
        #expect(try valid.contributes.decode(DocumentViewContributionPoint.self).first?.extensions == ["csv"])
        #expect(try valid.contributes.decode(AIContextContributionPoint.self).first?.byteLimit == 2048)
        for (point, invalid) in [(MenuContributionPoint.id, #"{"command": "refresh", "menu": "tools"}"#),
                                 (ToolbarContributionPoint.id, #"{"command": "refresh", "icon": "Arrow Path"}"#),
                                 (DocumentViewContributionPoint.id, #"{"id": "table", "title": "Table", "extensions": [], "entryPoint": "document"}"#),
                                 (DocumentViewContributionPoint.id, #"{"id": "table", "title": "Table", "extensions": ["CSV"], "entryPoint": "document"}"#),
                                 (AIContextContributionPoint.id, #"{"id": "summary", "title": "Summary", "entryPoint": "context", "maxBytes": 99999}"#),
                                 (AIToolContributionPoint.id, #"{"entryPoint": "components", "title": "Components", "description": "x"}"#)] {
            #expect(throws: PluginManifestValidationError.invalidContribution(point)) {
                try PluginManifestValidator.decodeAndValidate(manifest(#"{"\#(point)": [\#(invalid)]}"#))
            }
        }

        let runtime = try contract("""
            record document-input { view: string, state: string, event: string, context: string }
            document: func(input: document-input) -> string;
            record context-input { workspace: string, selection: string }
            context: func(input: context-input) -> string;
            """)
        let view = DocumentViewContribution(id: "table", title: "Table", extensions: ["csv"], entryPoint: "document")
        try DocumentViewContributionPoint.validateRuntime(view, contract: runtime)
        try AIContextContributionPoint.validateRuntime(
            AIContextContribution(id: "summary", title: "Summary", entryPoint: "context"), contract: runtime)
        try AIToolContributionPoint.validateRuntime(
            AIToolContribution(entryPoint: "document", title: "Doc", description: "x"), contract: runtime)
        #expect(throws: PluginManifestValidationError.invalidContribution(AIToolContributionPoint.id)) {
            try AIToolContributionPoint.validateRuntime(
                AIToolContribution(entryPoint: "missing", title: "Missing", description: "x"), contract: runtime)
        }
        #expect(throws: PluginManifestValidationError.invalidContribution(AIContextContributionPoint.id)) {
            try AIContextContributionPoint.validateRuntime(
                AIContextContribution(id: "summary", title: "Summary", entryPoint: "document"), contract: runtime)
        }
    }

    @Test("a view result carries a component tree, the state to hand back and effects")
    func viewResultIsDecoded() throws {
        let result = try PluginViewResult(json: Data("""
            {"state": {"items": ["Ship"]},
             "ui": {"type": "column", "spacing": 8, "children": [
               {"type": "textField", "id": "draft", "placeholder": "New item", "value": "", "submit": "add"},
               {"type": "row", "align": "center", "children": [
                 {"type": "toggle", "id": "done-0", "value": true, "action": "toggle"},
                 {"type": "text", "text": "Ship", "tone": "muted", "flex": 1},
                 {"type": "button", "title": "Remove", "style": "ghost", "action": "remove", "arguments": {"index": 0}}]},
               {"type": "select", "id": "filter", "value": "all", "options": [{"value": "all", "label": "All"}]},
               {"type": "disclosure", "title": "More", "expanded": false, "action": "expand", "children": [
                 {"type": "table", "columns": ["a", "b"], "rows": [{"cells": ["1", "2"], "action": "pick"}]}]},
               {"type": "progress", "percent": 40}, {"type": "spacer"}, {"type": "badge", "text": "1 open"}]},
             "effects": [{"type": "message", "text": "Added"}, {"type": "panel", "id": "checklist"},
                         {"type": "open", "path": "notes/todo.md"}]}
            """.utf8), panels: ["checklist"])
        #expect(result.state == .object(["items": .array([.string("Ship")])]))
        #expect(result.effects == [.message("Added"), .panel("checklist"), .open(path: "notes/todo.md")])
        guard case let .column(stack) = result.ui.kind else { Issue.record("not a column"); return }
        #expect(stack.spacing == 8 && stack.children.count == 7)
        guard case let .textField(field) = stack.children[0].kind else { Issue.record("not a field"); return }
        #expect(field.submit == "add" && field.value == "")

        let unchanged = try PluginViewResult(json: Data(#"{"ui": {"type": "spacer"}}"#.utf8), panels: [])
        #expect(unchanged.state == nil && unchanged.effects.isEmpty)
    }

    @Test("view results stay within bounds and name only what the host knows")
    func viewResultIsValidated() throws {
        func ui(_ node: String) -> Data { Data(#"{"ui": \#(node)}"#.utf8) }
        let deep = String(repeating: #"{"type": "column", "children": ["#, count: 30) + #"{"type": "spacer"}"#
            + String(repeating: "]}", count: 30)
        let invalid: [Data] = [
            ui(#"{"type": "canvas"}"#),
            ui(#"{"type": "button", "action": "add"}"#),
            ui(#"{"type": "button", "title": "Go", "action": "Not An Action"}"#),
            ui(#"{"type": "column", "children": [{"type": "toggle", "id": "a", "value": true}, {"type": "toggle", "id": "a", "value": false}]}"#),
            ui(#"{"type": "select", "id": "s", "value": "missing", "options": [{"value": "a", "label": "A"}]}"#),
            ui(#"{"type": "table", "columns": ["a", "b"], "rows": [{"cells": ["only one"]}]}"#),
            ui(#"{"type": "column", "spacing": 99, "children": []}"#),
            ui(#"{"type": "progress", "percent": 140}"#),
            ui(#"{"type": "button", "title": "Go", "action": "go", "arguments": [1]}"#),
            ui(#"{"type": "icon", "name": "../escape"}"#),
            ui(deep),
            Data(#"{"ui": {"type": "spacer"}, "effects": [{"type": "panel", "id": "terminal"}]}"#.utf8),
            Data(#"{"ui": {"type": "spacer"}, "effects": [{"type": "open", "path": "../secrets"}]}"#.utf8),
            Data(#"{"ui": {"type": "spacer"}, "effects": [{"type": "open", "path": "/etc/hosts"}]}"#.utf8),
            Data(#"{"ui": {"type": "spacer"}, "state": "\#(String(repeating: "x", count: 50_000))"}"#.utf8),
            Data("not json".utf8),
        ]
        for data in invalid {
            #expect(throws: PluginWorkbenchResultError.invalidView) { try PluginViewResult(json: data, panels: ["checklist"]) }
        }
    }

    @Test("a command returns effects for the host to carry out")
    func commandResultIsValidated() throws {
        let result = try PluginCommandResult(json: Data(#"{"effects": [{"type": "error", "text": "Failed"}]}"#.utf8),
                                             panels: [])
        #expect(result.effects == [.error("Failed")])
        #expect(try PluginCommandResult(json: Data("{}".utf8), panels: []) == PluginCommandResult())
        for invalid in [#"{"effects": [{"type": "panel", "id": "terminal"}]}"#, #"{"effects": [{"type": "message", "text": ""}]}"#, "[]"] {
            #expect(throws: PluginWorkbenchResultError.invalidCommandResult) {
                try PluginCommandResult(json: Data(invalid.utf8), panels: ["status"])
            }
        }
    }

    @Test("a harness runs an agent's turns, is called with whole turns and never reaches the model")
    func harnessIsValidated() throws {
        let valid = try PluginManifestValidator.decodeAndValidate(manifest("""
            {"guava.ai.harness/v1": [{"id": "careful", "title": "Careful", "entryPoint": "harness"}],
             "guava.ai.agent/v1": [{"id": "careful", "title": "Careful", "harness": "careful"}],
             "guava.ai.tool/v1": [{"entryPoint": "harness", "title": "Harness", "description": "Not a tool."}]}
            """))
        #expect(try valid.contributes.decode(AgentContributionPoint.self).first?.harness == "careful")
        #expect(!valid.exposesToAI(entryPoint: "harness"))
        let package = ValidatedPluginPackage(rootURL: URL(fileURLWithPath: "/careful.guavaplugin"), manifest: valid, runtime: nil)
        #expect(package.isHostEntryPoint("harness"))
        #expect(!package.isHostEntryPoint("other"))

        let runtime = try contract("""
            record harness-input { turn: string }
            harness: func(input: harness-input) -> string;
            record other-input { text: string }
            other: func(input: other-input) -> string;
            """)
        try AIHarnessContributionPoint.validateRuntime(AIHarnessContribution(id: "careful", title: "Careful", entryPoint: "harness"),
                                                       contract: runtime)
        #expect(throws: PluginManifestValidationError.invalidContribution(AIHarnessContributionPoint.id)) {
            try AIHarnessContributionPoint.validateRuntime(AIHarnessContribution(id: "careful", title: "Careful", entryPoint: "other"),
                                                           contract: runtime)
        }
        for invalid in [#"{"guava.ai.harness/v1": [{"id": "Careful", "title": "Careful", "entryPoint": "harness"}]}"#,
                        #"{"guava.ai.agent/v1": [{"id": "careful", "title": "Careful", "harness": "Not An Id"}]}"#] {
            #expect(throws: PluginManifestValidationError.self) { try PluginManifestValidator.decodeAndValidate(manifest(invalid)) }
        }
    }

    @Test("events carry the action, the raising control's value and every control value")
    func eventEncodes() throws {
        let event = UIEvent(action: "add", arguments: .object(["list": .string("today")]), value: .string("Ship"),
                            values: ["draft": .string("Ship"), "done": .bool(true)])
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        #expect(object["action"] as? String == "add")
        #expect((object["values"] as? [String: Any])?["done"] as? Bool == true)
        #expect((object["arguments"] as? [String: Any])?["list"] as? String == "today")
    }
}
