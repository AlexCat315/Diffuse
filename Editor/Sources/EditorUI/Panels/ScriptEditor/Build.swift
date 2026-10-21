internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime

/// The selected script's build state and the button that builds or stops it.
struct ScriptBuildControl: View {
    let app: EditorApplication
    let document: ScriptWorkspaceDocument
    let allowsExecution: Bool

    var body: some View {
        let status = ScriptBuildStatus(document)
        Row(alignment: .center, spacing: 8) {
            Row(alignment: .center, spacing: 5) {
                Box { EmptyView() }.frame(width: 6, height: 6).background(status.color).cornerRadius(3)
                Text(status.label, lineLimit: 1).font(.caption).foregroundColor(status.color)
            }.debugName("script-build-status")
            if document.buildState.isBuilding {
                Button(icon: .resource(UIIcons.Editor.stop), size: 11, tooltip: L("Stop Build"),
                       action: app.workstation.scripts.cancelSelectedBuild)
                    .buttonStyle(.destructive).debugName("script-build-stop")
            } else {
                Button(isEnabled: allowsExecution, tooltip: L("Build & Reload"),
                       action: app.workstation.scripts.compileSelected) {
                    Row(alignment: .center, spacing: 4) {
                        Icon(UIIcons.Editor.play, size: 10)
                        Text(L("Build")).font(.label)
                    }
                }.buttonStyle(.primary).debugName("script-build")
            }
        }
    }
}

/// What a script's source and build say right now, in one word and a color.
struct ScriptBuildStatus {
    let label: String
    let color: SemanticColorRef

    init(_ document: ScriptWorkspaceDocument) {
        if document.externalChange.requiresResolution { (label, color) = (L("Source Changed"), .warning); return }
        if document.isDirty { (label, color) = (L("Modified"), .warning); return }
        switch document.buildState {
        case .succeeded:
            (label, color) = document.loadedRevision == document.editRevision
                ? (L("Built"), .success) : (L("Not Applied"), .warning)
        case .failed: (label, color) = (L("Build failed"), .error)
        case .building: (label, color) = (L("Building"), .accent)
        case .blocked: (label, color) = (L("Restricted"), .warning)
        case .idle: (label, color) = (L("Not Built"), .onSurfaceMuted)
        case .cancelled: (label, color) = (L("Cancelled"), .onSurfaceMuted)
        }
    }
}
