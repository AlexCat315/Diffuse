import EditorCore
import EngineKernel
import GuavaUI
import GuavaUIRuntime
import GuavaUIWorkspace
import Foundation

struct EditorRootView: View {
    let app: EditorApplication
    let controller: WorkspaceController
    let registry: WorkspacePanelRegistry
    @State private var windowWidth: Float = 1280
    @State private var windowHeight: Float = 720

    var body: some View {
        StoreScope(app.store) { store in
            let cb = EditorCallbacks(app: app, controller: controller, registry: registry,
                                     commandPaletteVisible: store.commandPaletteVisible)
            EditorPresentationBoundary(presentation: store.presentation) {
                LayerRoot {
                    Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        ShortcutHost(onKeyDown: cb.handleShortcut)

                        EditorTitleBar(app: app, width: windowWidth, onCommand: cb.handleMenuCommand)
                        Divider()
                        Box(direction: .row, alignItems: .stretch, spacing: 0) {
                            EditorActivityRail(app: app, controller: controller, onCommand: cb.handleMenuCommand)
                            Divider(axis: .vertical)
                            WorkspaceView(controller: controller,
                                           registry: registry, compact: windowWidth < 1000)
                                .flex()
                                .frame(minWidth: 0, minHeight: 0)
                                .workspaceTheme(WorkspaceTheme(tabBarHeight: 32, splitDividerThickness: 1,
                                                              animatesLayout: true, panelStyle: .continuous))
                                .layoutRole("editor-workspace")
                                .debugName("editor-workspace")
                        }.flex().frame(minWidth: 0, minHeight: 0)

                        Divider()
                        EditorStatusBar(app: app, controller: controller, onCommand: cb.handleMenuCommand)
                    }
                    .background(.background)
                    .flex()
                    .frame(width: .percent(100),
                           height: .percent(100),
                           minWidth: 0,
                           minHeight: 0)
                    .modifier(EditorWindowSizeObserver(width: $windowWidth, height: $windowHeight))
                } portals: {
                    PortalHost()
                    CommandPalettePresentation(app: app, controller: controller, registry: registry,
                                               availableHeight: windowHeight)
                    if let pendingClose = store.pendingCloseRequest {
                        UnsavedChangesDialog(app: app, request: pendingClose)
                    }
                }
            }
        }
    }
}

private struct EditorWindowSizeObserver: ViewModifier {
    let width: Binding<Float>
    let height: Binding<Float>
    func apply(node: Node) {
        node.layoutDidUpdate = { node in
            let next = Float(node.frame.width)
            if next > 0, abs(width.wrappedValue - next) > 1 { width.wrappedValue = next }
            let nextHeight = Float(node.frame.height)
            if nextHeight > 0, abs(height.wrappedValue - nextHeight) > 1 { height.wrappedValue = nextHeight }
        }
    }
}

private struct EditorCallbacks {
    let handleShortcut: (KeyEvent) -> Bool
    let handleMenuCommand: (EditorCommand) -> Void

    init(app: EditorApplication,
         controller: WorkspaceController,
         registry: WorkspacePanelRegistry,
         commandPaletteVisible: Bool) {
        let perform: (EditorCommand) -> Void = { command in
            EditorCommandDispatcher.handle(command, app: app, controller: controller, registry: registry)
        }
        handleMenuCommand = perform
        handleShortcut = { key in
            EditorShortcutHandler.handle(key,
                                         catalog: .make(EditorCommandContext(app: app)),
                                         commandPaletteVisible: commandPaletteVisible,
                                         closeCommandPalette: { app.store.dispatch(.setCommandPaletteVisible(false)) },
                                         perform: perform)
        }
    }
}
