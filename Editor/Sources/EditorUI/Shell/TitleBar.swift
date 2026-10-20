internal import EditorCore
private import Foundation
internal import GuavaUI
internal import GuavaUIRuntime

struct EditorTitleBar: View {
    let app: EditorApplication
    let width: Float
    var menuPresentation: EditorMenuPresentation = .current
    let onCommand: (EditorCommand) -> Void

    var body: some View {
        let store = app.store
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            ImmersiveWindowTitleBar(height: 40) {
                Row(alignment: .center, spacing: 10) {
                    if menuPresentation == .titleBar {
                        EditorTitleMenu(catalog: catalog, onCommand: onCommand).id("title-menu")
                    }
                    project.id("title-project")
                    if width >= 1180 { selection.flex().frame(minWidth: 0).clipped().id("title-selection") }
                    WindowDragRegion().frame(minWidth: 12).id("title-drag")
                    intent.frame(width: width >= 1380 ? 300 : width >= 1100 ? 240 : 32).id("title-intent")
                    EditorSpaceSwitcher(mode: store.workspaceMode,
                                        presentation: width < 680 ? .menu : width < 1260 ? .icons : .labels,
                                        onCommand: onCommand).id("title-spaces")
                    if width >= 1100 {
                        Icon(UIIcons.Status.sparkles, size: 13, color: EditorChromeTokens.agentColor)
                            .frame(width: 24, height: 24)
                            .background(EditorChromeTokens.agentColor.opacity(0.12)).cornerRadius(12).id("title-presence")
                    }
                    if store.workspaceMode.isGameWorkspace {
                        EditorPlaybackToolbar(state: store.playbackState, compact: width < 520, onCommand: onCommand)
                            .id("title-playback")
                    }
                }.flex().frame(minWidth: 0)
            }
        }
        .frame(height: 40).debugName("editor-title-bar")
    }

    /// Reads the observed store values the catalog depends on, so the title-bar
    /// menu refreshes with selection, history and playback.
    private var catalog: EditorCommandCatalog {
        let store = app.store
        let _ = store.sceneRevision
        return .make(EditorCommandContext(workspaceMode: store.workspaceMode,
                                          layoutPreset: store.activeLayoutPreset,
                                          playbackState: store.playbackState,
                                          canUndo: app.canUndo,
                                          canRedo: app.canRedo,
                                          hasSelection: !store.selectedEntityIDs.isEmpty))
    }

    private var intentShortcut: String {
        catalog.entries.first { $0.id == "agent.intent" }?.shortcut?.label ?? ""
    }

    private var project: some View {
        Button(tooltip: L("Project commands")) {
            onCommand(.showCommandPalette(.commands))
        } label: {
            Row(alignment: .center, spacing: 7) {
                Text("G").font(.bodyStrong).foregroundColor(.onAccent)
                    .frame(width: 21, height: 21).background(.accent).cornerRadius(6)
                if width >= 800 {
                    Text(URL(fileURLWithPath: app.projectDirectory).lastPathComponent, lineLimit: 1)
                        .font(.bodyStrong).frame(maxWidth: 150)
                    Icon(UIIcons.Navigation.chevronDown, size: 9, color: .onSurfaceMuted)
                }
            }
        }.buttonStyle(EditorChromeButtonStyle()).debugName("editor-project")
    }

    private var selection: some View {
        Row(alignment: .center, spacing: 6) {
            Icon(UIIcons.Shape.globe, size: 12, color: .onSurfaceMuted)
            Text(L("Scene"), lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted)
            if let entity = app.scene.entitySummary(id: app.store.selectedEntityID) {
                Icon(UIIcons.Navigation.chevronRight, size: 9, color: .onSurfaceMuted)
                Text(entity.name, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceVariant)
            }
        }.debugName("editor-breadcrumb")
    }

    private var intent: some View {
        Button(tooltip: L("Tell Guava what you want to do…")) {
            onCommand(.showCommandPalette(.intent))
        } label: {
            Row(alignment: .center, spacing: 7) {
                Icon(UIIcons.Status.sparkles, size: 13, color: EditorChromeTokens.agentColor)
                if width >= 1100 {
                    Text(L("Tell Guava what you want to do…"), lineLimit: 1)
                        .font(.caption).foregroundColor(.onSurfaceMuted).flex()
                    Text(intentShortcut).font(.caption)
                        .foregroundColor(.onSurfaceMuted).padding(horizontal: 4)
                        .border(.borderStrong, width: 1).cornerRadius(3)
                }
            }.padding(horizontal: 9).frame(height: 28).frame(minWidth: 0)
                .background(.surfaceSunken).cornerRadius(8).border(.borderStrong, width: 1)
        }.buttonStyle(.plain).debugName("editor-intent-bar")
    }
}
