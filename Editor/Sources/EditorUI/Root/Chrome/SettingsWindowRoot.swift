internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime

struct EditorSettingsWindowRoot: View {
    let app: EditorApplication
    @State private var session: EditorSettingsSession

    init(app: EditorApplication) {
        self.app = app
        _session = State(wrappedValue: EditorSettingsSession(settings: app.store.aiSettings))
    }

    var body: some View {
        StoreScope(app.store) { store in
            EditorPresentationBoundary(presentation: store.presentation) {
                // The settings window is borderless (immersive) like the main
                // window, so it must mount its own title bar (drag region +
                // minimize / maximize / close) and a PortalHost for any popovers.
                LayerRoot {
                    Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        EditorCanvasChrome {
                            ImmersiveWindowTitleBar(height: 40) {
                                Text(L("Settings")).font(.label).foregroundColor(.onSurfaceVariant)
                                    .padding(EdgeInsets(leading: 6))
                            }
                        }.frame(height: 40)

                        SettingsPanel(app: app, session: session)
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
