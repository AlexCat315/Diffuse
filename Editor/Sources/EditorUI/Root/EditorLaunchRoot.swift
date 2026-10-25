import EditorCore
import GuavaUI
import GuavaUIRuntime
import GuavaUIWorkspace

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
            EditorProjectlessRoot(context: context)
                .theme(EditorVisualTheme.make(dark: context.shellState?.themeMode != .light,
                                            themeID: context.shellState?.themeID ?? EditorThemeCatalog.defaultThemeID))
                .controlSize(.small)
        }
    }
}
