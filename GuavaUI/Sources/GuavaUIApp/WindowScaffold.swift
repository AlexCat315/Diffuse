import GuavaUICompose
import GuavaUIRuntime

/// A root scaffold for the immersive (borderless) title-bar style.
///
/// It mounts the platform window chrome — a draggable bar with the
/// minimize / maximize / close controls (`ImmersiveWindowTitleBar`) — above your
/// content, so screens never hand-roll the title bar and a borderless window can
/// never end up unmovable or unclosable.
///
/// Convenient: `WindowScaffold { myContent }` already gives a working, draggable
/// title bar with window controls. Flexible: pass a `titleBar` slot to place
/// your own leading content (an app menu bar, a document title, …) next to the
/// controls, and vary it per screen.
///
/// ```swift
/// // Welcome screen — just a title:
/// WindowScaffold {
///     Text("GuavaNext Editor")
/// } content: {
///     WelcomeBody()
/// }
///
/// // Editor screen — a full menu bar:
/// WindowScaffold {
///     EditorApplicationMenuBar(...)
/// } content: {
///     PanelWorkspace(...)
/// }
/// ```
public struct WindowScaffold<TitleBar: View, Content: View>: View {
    private let titleBarHeight: Float
    private let titleBar: TitleBar
    private let content: Content

    public init(titleBarHeight: Float = 34,
                @ViewBuilder titleBar: () -> TitleBar = { EmptyView() },
                @ViewBuilder content: () -> Content) {
        self.titleBarHeight = titleBarHeight
        self.titleBar = titleBar()
        self.content = content()
    }

    public var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            ImmersiveWindowTitleBar(height: titleBarHeight) {
                titleBar
            }
            content
                .flex()
                .frame(minWidth: 0, minHeight: 0)
        }
        .flex()
    }
}
