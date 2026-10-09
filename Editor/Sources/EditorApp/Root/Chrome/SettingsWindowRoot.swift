import EditorCore
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import Foundation

struct EditorSettingsWindowRoot: View {
    let app: EditorApplication

    var body: some View {
        StoreScope(app.store) { store in
            EditorPresentationBoundary(presentation: store.presentation) {
                // The settings window is borderless (immersive) like the main
                // window, so it must mount its own title bar (drag region +
                // minimize / maximize / close) and a PortalHost for any popovers.
                LayerRoot {
                    Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        ImmersiveWindowTitleBar {
                            Text(L("Settings"))
                                .font(.label)
                                .foregroundColor(.onSurfaceMuted)
                                .padding(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 0))
                        }

                        Divider()

                        SettingsPanel(app: app)
                            .flex()
                    }
                    .background(.background)
                    .flex()
                    .frame(width: .percent(100),
                           height: .percent(100),
                           minWidth: 0,
                           minHeight: 0)
                } portals: {
                    PortalHost()
                }
            }
        }
    }
}
