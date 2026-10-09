import EditorCore
import GuavaUIApp

enum EditorWorkspacePanelPolicy {
    static func registry(for mode: EditorWorkspaceMode, from registry: PanelRegistry) -> PanelRegistry {
        PanelRegistry(registry.descriptors.filter { mode.profile.allowsPanel($0.id.rawValue) })
    }
}
