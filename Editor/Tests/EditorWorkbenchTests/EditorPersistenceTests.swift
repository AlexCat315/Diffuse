import Foundation
import GuavaUIApp
import GuavaUICompose
import GuavaUIWorkspace
import Testing
@testable import EditorApp

@Suite("Editor persistence")
struct EditorPersistenceTests {
    @Test("the active legacy profiler migrates to Developer Tools without duplicate docking")
    func profilerMigration() {
        let registry = PanelRegistry([
            PanelDescriptor(id: "developer-tools", title: "Developer Tools", preferredSlot: .bottom) { EmptyView() },
            PanelDescriptor(id: "console", title: "Console", preferredSlot: .bottom) { EmptyView() },
        ])
        let document = WorkspaceDocument(
            panels: ["profiler": WorkspacePanel(id: "profiler", title: "Profiler"),
                     "developer-tools": WorkspacePanel(id: "developer-tools", title: "Developer Tools"),
                     "console": WorkspacePanel(id: "console", title: "Console")],
            groups: ["a": WorkspaceTabGroup(id: "a", panels: ["developer-tools"], activePanelID: "developer-tools"),
                     "bottom": WorkspaceTabGroup(id: "bottom", panels: ["console", "profiler"], activePanelID: "profiler")],
            slots: WorkspaceSlot.standardEditorSlots(center: .group("a"), bottom: .group("bottom")),
            layoutTree: .group("a"))
        let migrated = EditorRootViewFactory.reconciledWorkspaceDocument(document, registry: registry)
        #expect(migrated.group("bottom")?.activePanelID == "developer-tools")
        #expect(migrated.groups.values.flatMap(\.panels).filter { $0 == "developer-tools" }.count == 1)
        #expect(migrated.panels["profiler"] == nil)
        #expect(migrated.hasValidLayoutReferences)
    }
    @Test("Invalid persisted state is quarantined instead of deleted")
    func invalidStateIsQuarantined() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-editor-persistence-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("editor_shell_state.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("{ malformed state".utf8)
        try original.write(to: url, options: .atomic)

        let quarantinedURL = try #require(
            EditorRootViewFactory.quarantinePersistenceFile(
                at: url,
                label: "test state",
                reason: "invalid JSON"
            )
        )

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: quarantinedURL.path))
        #expect(try Data(contentsOf: quarantinedURL) == original)
        #expect(quarantinedURL.lastPathComponent.hasPrefix("editor_shell_state.corrupt-"))
        #expect(quarantinedURL.pathExtension == "json")
    }

    @Test("Quarantine is a no-op when persisted state is absent")
    func absentStateIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-editor-persistence-absent-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let result = EditorRootViewFactory.quarantinePersistenceFile(
            at: url,
            label: "test state",
            reason: "missing"
        )

        #expect(result == nil)
        #expect((try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
    }

    @Test("Workspace reconciliation preserves closed panels while adding new descriptors")
    func workspaceReconciliationPreservesClosedPanels() {
        let registry = PanelRegistry([
            PanelDescriptor(id: "assets", title: "Assets", preferredSlot: .bottom) {
                EmptyView()
            },
            PanelDescriptor(id: "new-tool", title: "New Tool", preferredSlot: .bottom) {
                EmptyView()
            },
        ])
        let document = WorkspaceDocument(
            panels: ["assets": WorkspacePanel(id: "assets", title: "Assets")],
            groups: [:],
            slots: WorkspaceSlot.standardEditorSlots(),
            closedHistory: [
                WorkspaceClosedPanel(panelID: "assets",
                                     groupID: "bottom",
                                     slotID: .bottom,
                                     index: 0),
            ]
        )

        let reconciled = EditorRootViewFactory.reconciledWorkspaceDocument(
            document,
            registry: registry
        )

        #expect(reconciled.groupContaining(panelID: "assets") == nil)
        #expect(reconciled.closedHistory.map(\.panelID) == ["assets"])
        #expect(reconciled.groupContaining(panelID: "new-tool")?.panels.contains("new-tool") == true)
    }

    @Test("workspace reconciliation preserves the user's Scripts docking position")
    func scriptsPanelPlacementIsPreserved() {
        let registry = PanelRegistry([
            PanelDescriptor(id: "viewport", title: "Viewport", preferredSlot: .center) {
                EmptyView()
            },
            PanelDescriptor(id: "scripts", title: "Scripts", preferredSlot: .center) {
                EmptyView()
            },
            PanelDescriptor(id: "assets", title: "Assets", preferredSlot: .bottom) {
                EmptyView()
            },
        ])
        let panels: [WorkspacePanelID: WorkspacePanel] = [
            "viewport": WorkspacePanel(id: "viewport", title: "Viewport"),
            "scripts": WorkspacePanel(id: "scripts", title: "Scripts"),
            "assets": WorkspacePanel(id: "assets", title: "Assets"),
        ]
        let document = WorkspaceDocument(
            panels: panels,
            groups: [
                "center": WorkspaceTabGroup(id: "center", panels: ["viewport"], activePanelID: "viewport"),
                "bottom": WorkspaceTabGroup(id: "bottom", panels: ["assets", "scripts"], activePanelID: "scripts"),
            ],
            slots: WorkspaceSlot.standardEditorSlots(center: .group("center"), bottom: .group("bottom")),
            layoutTree: .group("center")
        )

        let reconciled = EditorRootViewFactory.reconciledWorkspaceDocument(document, registry: registry)

        #expect(reconciled.group("center")?.panels == ["viewport"])
        #expect(reconciled.group("center")?.activePanelID == "viewport")
        #expect(reconciled.group("bottom")?.panels == ["assets", "scripts"])
        #expect(reconciled.group("bottom")?.activePanelID == "scripts")
        #expect(reconciled.slotContaining(groupID: "center") == .center)
    }

    @Test("the workbench's side-by-side scene and script survive save/reload reconciliation")
    func workbenchSplitSurvivesReload() throws {
        let registry = PanelRegistry([
            PanelDescriptor(id: "viewport", title: "Viewport", preferredSlot: .center) { EmptyView() },
            PanelDescriptor(id: "scripts", title: "Scripts", preferredSlot: .center) { EmptyView() },
            PanelDescriptor(id: "hierarchy", title: "Hierarchy", preferredSlot: .leading) { EmptyView() },
            PanelDescriptor(id: "inspector", title: "Inspector", preferredSlot: .trailing) { EmptyView() },
            PanelDescriptor(id: "profiler", title: "Profiler", preferredSlot: .bottom) { EmptyView() },
        ])
        let document = EditorWorkspaceDefaults.makeDocument(mode: .level, preset: .levelWorkbench,
                                                            registry: registry)
        let saved = try JSONDecoder().decode(WorkspaceDocument.self,
                                            from: JSONEncoder().encode(document))
        let reconciled = EditorRootViewFactory.reconciledWorkspaceDocument(saved, registry: registry)
        let expected = WorkspaceLayoutNode.split(axis: .horizontal, fraction: 0.54,
                                                  first: .group("center"), second: .group("script-editor"))
        #expect(reconciled.slot(.center).layout == expected)
        #expect(reconciled.group("center")?.panels == ["viewport"])
        #expect(reconciled.group("script-editor")?.panels == ["scripts"])
        #expect(reconciled.group("bottom")?.activePanelID == "profiler")
        #expect(reconciled.hasValidLayoutReferences)
    }
}
