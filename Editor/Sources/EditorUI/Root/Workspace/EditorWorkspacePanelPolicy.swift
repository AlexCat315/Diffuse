import GuavaUIWorkspace
import EditorCore
import GuavaUI

enum EditorWorkspacePanelPolicy {
    static func registry(for mode: EditorWorkspaceMode, from registry: WorkspacePanelRegistry) -> WorkspacePanelRegistry {
        WorkspacePanelRegistry(registry.descriptors.filter { mode.profile.allowsPanel($0.panel.id.rawValue) })
    }
}
