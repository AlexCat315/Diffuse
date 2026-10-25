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
            record panel-input { panel: string }
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
            record document-input { path: string, text: string }
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

    @Test("panel content names only the package's own commands and stays within bounds")
    func panelModelIsValidated() throws {
        let model = try PanelModel(json: """
            {"sections": [{"title": "Changes", "items": [
                {"title": "README.md", "detail": "modified", "badge": "M", "tone": "warning",
                 "command": "open", "arguments": {"path": "README.md"}}]}],
             "actions": [{"title": "Refresh", "command": "refresh"}]}
            """, commands: ["open", "refresh"])
        #expect(model.sections.first?.items.first?.arguments == .object(["path": .string("README.md")]))
        #expect(model.actions.map(\.command) == ["refresh"])
        #expect(try PanelModel(json: #"{"empty": "Clean"}"#, commands: []).sections.isEmpty)

        let tooMany = (0..<9).map { #"{"title": "A\#($0)", "command": "refresh"}"# }.joined(separator: ",")
        for invalid in [#"{"actions": [{"title": "Delete", "command": "delete"}]}"#,
                        #"{"sections": [{"items": [{"title": "x", "arguments": {"a": 1}}]}]}"#,
                        #"{"sections": [{"items": [{"title": "x", "command": "open", "arguments": [1]}]}]}"#,
                        #"{"sections": [{"items": [{"title": ""}]}]}"#,
                        #"{"sections": [{"items": [{"title": "x", "tone": "loud"}]}]}"#,
                        #"{"actions": [\#(tooMany)]}"#,
                        "not json"] {
            #expect(throws: PluginWorkbenchResultError.invalidPanel) {
                try PanelModel(json: invalid, commands: ["open", "refresh"])
            }
        }
    }

    @Test("a command result may only bring forward the package's own panels")
    func commandResultIsValidated() throws {
        let result = try PluginCommandResult(json: #"{"message": "Done", "panel": "status"}"#, panels: ["status"])
        #expect(result == PluginCommandResult(message: "Done", panel: "status"))
        #expect(try PluginCommandResult(json: "{}", panels: []) == PluginCommandResult())
        for invalid in [#"{"panel": "terminal"}"#, #"{"message": ""}"#, "[]"] {
            #expect(throws: PluginWorkbenchResultError.invalidCommandResult) {
                try PluginCommandResult(json: invalid, panels: ["status"])
            }
        }
    }
}
