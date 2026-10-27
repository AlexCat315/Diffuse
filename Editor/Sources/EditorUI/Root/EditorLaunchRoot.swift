import EditorCore
import CoveUI
import CoveUIRuntime
import CoveUIWorkspace

/// The window's editor. A window always has a workspace — the project in front,
/// or the untitled one the editor makes when there is no project yet — so this
/// never swaps the whole editor out for a different screen.
struct EditorLaunchRoot: View {
    let context: EditorLaunchContext

    // Raw Observed to avoid "cannot use instance member within property initializer".
    private var _active: Observed<EditorLaunchContext, String?>
    private var active: String? { _active.wrappedValue }

    init(context: EditorLaunchContext) {
        self.context = context
        self._active = Observed(\.activeDirectory, on: context)
    }

    var body: some View {
        if let active, let bundle = context.bundle(for: active) {
            if EditorAppLaunchOptions.settingsRequested {
                EditorSettingsWindowRoot(app: bundle.app)
            } else {
                // Each project keeps its own view state; switching rebuilds the window around it.
                EditorRootView(app: bundle.app,
                               controller: bundle.controller,
                               registry: bundle.registry,
                               projects: context)
                    .id(active)
            }
        } else {
            // Only while the window has no editor at all, which is a failure to
            // open rather than a mode the user can sit in.
            EditorWorkspaceUnavailable(context: context)
                .theme(EditorVisualTheme.make(dark: context.shellState?.themeMode != .light,
                                              themeID: context.shellState?.themeID ?? EditorThemeCatalog.defaultThemeID))
                .controlSize(.small)
        }
    }
}

/// Shown only when no workspace could be opened — the window says why and
/// offers the two ways to get one, instead of drawing a fake editor.
private struct EditorWorkspaceUnavailable: View {
    let context: EditorLaunchContext
    private var failure: Observed<EditorLaunchContext, String?>

    init(context: EditorLaunchContext) {
        self.context = context
        failure = Observed(\.openFailure, on: context)
    }

    var body: some View {
        // Bind locally so the closures capture the context, not the view.
        let context = context
        let open = { MainActor.assumeIsolated { context.requestOpenFolder() } }
        let start = { MainActor.assumeIsolated { _ = context.openScratchWorkspace() } }
        return LayerRoot {
            Box(direction: .column, alignItems: .center, justifyContent: .center, spacing: 0) {
                Column(alignment: .center, spacing: 10) {
                    Text(L("The workspace could not be opened")).font(.bodyStrong).foregroundColor(.onSurface)
                    if let failure = failure.wrappedValue {
                        Text(failure, alignment: .center).font(.caption).foregroundColor(.error)
                            .frame(maxWidth: 360)
                    }
                    Row(alignment: .center, spacing: 6) {
                        Button(L("Untitled Workspace"), action: start)
                            .buttonStyle(EditorChromeButtonStyle(height: 30, agent: true))
                            .debugName("workspace-unavailable-start")
                        Button(L("Open Folder..."), action: open)
                            .buttonStyle(EditorChromeButtonStyle(height: 30))
                            .debugName("workspace-unavailable-open")
                    }.padding(EdgeInsets(top: 6))
                }.padding(24)
            }.background(.background).flex().frame(minWidth: 0, minHeight: 0)
        }
    }
}
