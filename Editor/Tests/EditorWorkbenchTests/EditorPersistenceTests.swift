import Foundation
import GuavaUI
import GuavaUICompose
import GuavaUIWorkspace
import Testing
@testable import EditorUI

@Suite("Editor persistence")
struct EditorPersistenceTests {
    @Test("the active legacy profiler migrates to Developer Tools without duplicate docking")
    func profilerMigration() {
        let registry = WorkspacePanelRegistry([
            WorkspacePanelDescriptor(id: "developer-tools", title: "Developer Tools", defaultSlot: .bottom, configure: { $0.isCollapsible = true }) { EmptyView() },
            WorkspacePanelDescriptor(id: "console", title: "Console", defaultSlot: .bottom, configure: { $0.isCollapsible = true }) { EmptyView() },
        ])
        let document = WorkspaceDocument(
            panels: ["profiler": WorkspacePanel(id: "profiler", title: "Profiler"),
                     "developer-tools": WorkspacePanel(id: "developer-tools", title: "Developer Tools"),
                     "console": WorkspacePanel(id: "console", title: "Console")],
            groups: ["a": WorkspaceTabGroup(id: "a", panels: ["developer-tools"], activePanelID: "developer-tools"),
                     "bottom": WorkspaceTabGroup(id: "bottom", panels: ["console", "profiler"], activePanelID: "profiler")],
            slots: WorkspaceSlot.standardEditorSlots(center: .group("a"), bottom: .group("bottom")))
        let migrated = EditorRootViewFactory.reconciledWorkspaceDocument(document, registry: registry)
        #expect(migrated.group("bottom")?.activePanelID == "developer-tools")
        #expect(migrated.groups.values.flatMap(\.panels).filter { $0 == "developer-tools" }.count == 1)
        #expect(migrated.panels["profiler"] == nil)
        #expect(migrated.hasValidLayoutReferences)
    }
    @Test("Invalid persisted state is quarantined instead of deleted")
    func invalidStateIsQuarantined() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-studio-persistence-\(UUID().uuidString)")
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
            .appendingPathComponent("guava-studio-persistence-absent-\(UUID().uuidString)")
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
        let registry = WorkspacePanelRegistry([
            WorkspacePanelDescriptor(id: "assets", title: "Assets", defaultSlot: .bottom, configure: { $0.isCollapsible = true }) {
                EmptyView()
            },
            WorkspacePanelDescriptor(id: "new-tool", title: "New Tool", defaultSlot: .bottom, configure: { $0.isCollapsible = true }) {
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

    @Test("workspace reconciliation preserves the user's editor docking position")
    func editorPanelPlacementIsPreserved() {
        let registry = WorkspacePanelRegistry([
            WorkspacePanelDescriptor(id: "viewport", title: "Viewport", defaultSlot: .center, configure: { $0.isCollapsible = false }) {
                EmptyView()
            },
            WorkspacePanelDescriptor(id: "documents", title: "Editor", defaultSlot: .center, configure: { $0.isCollapsible = false }) {
                EmptyView()
            },
            WorkspacePanelDescriptor(id: "assets", title: "Assets", defaultSlot: .bottom, configure: { $0.isCollapsible = true }) {
                EmptyView()
            },
        ])
        let panels: [WorkspacePanelID: WorkspacePanel] = [
            "viewport": WorkspacePanel(id: "viewport", title: "Viewport"),
            "documents": WorkspacePanel(id: "documents", title: "Editor"),
            "assets": WorkspacePanel(id: "assets", title: "Assets"),
        ]
        let document = WorkspaceDocument(
            panels: panels,
            groups: [
                "center": WorkspaceTabGroup(id: "center", panels: ["viewport"], activePanelID: "viewport"),
                "bottom": WorkspaceTabGroup(id: "bottom", panels: ["assets", "documents"], activePanelID: "documents"),
            ],
            slots: WorkspaceSlot.standardEditorSlots(center: .group("center"), bottom: .group("bottom")))

        let reconciled = EditorRootViewFactory.reconciledWorkspaceDocument(document, registry: registry)

        #expect(reconciled.group("center")?.panels == ["viewport"])
        #expect(reconciled.group("center")?.activePanelID == "viewport")
        #expect(reconciled.group("bottom")?.panels == ["assets", "documents"])
        #expect(reconciled.group("bottom")?.activePanelID == "documents")
        #expect(reconciled.slotContaining(groupID: "center") == .center)
    }

    @Test("the workbench's side-by-side scene and code editor survive save/reload reconciliation")
    func workbenchSplitSurvivesReload() throws {
        let registry = WorkspacePanelRegistry([
            WorkspacePanelDescriptor(id: "viewport", title: "Viewport", defaultSlot: .center, configure: { $0.isCollapsible = false }) { EmptyView() },
            WorkspacePanelDescriptor(id: "documents", title: "Editor", defaultSlot: .center, configure: { $0.isCollapsible = false }) { EmptyView() },
            WorkspacePanelDescriptor(id: "hierarchy", title: "Hierarchy", defaultSlot: .leading, configure: { $0.isCollapsible = true }) { EmptyView() },
            WorkspacePanelDescriptor(id: "inspector", title: "Inspector", defaultSlot: .trailing, configure: { $0.isCollapsible = true }) { EmptyView() },
            WorkspacePanelDescriptor(id: "profiler", title: "Profiler", defaultSlot: .bottom, configure: { $0.isCollapsible = true }) { EmptyView() },
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
        #expect(reconciled.group("script-editor")?.panels == ["documents"])
        #expect(reconciled.group("bottom")?.activePanelID == "profiler")
        #expect(reconciled.hasValidLayoutReferences)
    }
}
