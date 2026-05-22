import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace

struct EditorLaunchRoot: View {
    let context: EditorLaunchContext

    // Raw Observed to avoid "cannot use instance member within property initializer".
    private var _isLoaded: Observed<EditorLaunchContext, Bool>
    private var isLoaded: Bool { _isLoaded.wrappedValue }

    init(context: EditorLaunchContext) {
        self.context = context
        self._isLoaded = Observed(\.isProjectLoaded, on: context)
    }

    var body: some View {
        if isLoaded, let bundle = context.bundle {
            EditorRootView(app: bundle.app,
                           controller: bundle.controller,
                           registry: bundle.registry)
        } else {
            WelcomeView(context: context)
        }
    }
}
