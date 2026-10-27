import EditorCore
import EngineKernel
import CoveUI
import CoveUIRuntime
import CoveUIWorkspace
import Foundation

struct EditorRootView: View {
    let app: EditorApplication
    let controller: WorkspaceController
    let registry: WorkspacePanelRegistry
    /// The window's projects; absent when a view shows one project on its own.
    var projects: EditorLaunchContext?
    @State private var windowWidth: Float = 1280
    @State private var windowHeight: Float = 720
    private let surface: EditorAssistantSurface
    private var session: Observed<EditorAssistantSurface, EditorAssistantSurface.State>

    init(app: EditorApplication, controller: WorkspaceController, registry: WorkspacePanelRegistry,
         projects: EditorLaunchContext? = nil) {
        self.app = app
        self.controller = controller
        self.registry = registry
        self.projects = projects
        let surface = EditorAssistantSurface.of(app)
        self.surface = surface
        session = Observed(\.state, on: surface)
    }

    var body: some View {
        StoreScope(app.store) { store in
            let _ = app.setPluginWorkScheduler(UIWorkSchedulerHolder.enqueue)
            // Redraw when the agent's own view state changes; `surface.view`
            // then decides whether that state is reachable at all.
            let surfaceState = session.wrappedValue
            let cb = EditorCallbacks(app: app, controller: controller, registry: registry,
                                     commandPaletteVisible: store.commandPaletteVisible)
            EditorPresentationBoundary(presentation: store.presentation,
                                       theme: app.resolvedTheme(dark: store.themeMode == .dark)) {
                if surfaceState.isReady {
                    LayerRoot {
                    Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        ShortcutHost(onKeyDown: cb.handleShortcut)

                        // Title bar, rail and status bar rest on the canvas; only panes are cards.
                        EditorCanvasChrome {
                            EditorTitleBar(app: app, width: windowWidth, projects: projects, onCommand: cb.handleMenuCommand)
                        }
                        // You work in the canvas; the agent works in its own view of the same project.
                        // A disabled agent plugin has no view at all, so the workbench takes the window.
                        Box(direction: .row, alignItems: .stretch, spacing: 0) {
                            if let panel = app.workbenchCatalog.panels.first(where: { panel in
                                guard let name = panel.surface else { return false }
                                return EditorStudioView(panel.pluginID + "." + name) == surface.view
                            }) {
                                PluginSurface(app: app, panel: panel)
                            } else {
                                EditorActivityRail(app: app, controller: controller, onCommand: cb.handleMenuCommand)
                                WorkspaceView(controller: controller, compact: windowWidth < 1000) {
                                    EditorRootViewFactory.content(for: $0, controller: controller, registry: registry)
                                }
                                    .flex()
                                    .frame(minWidth: 0, minHeight: 0)
                                    .padding(EdgeInsets(trailing: 6))
                                    .workspaceTheme(WorkspaceTheme(tabBarHeight: 32, animatesLayout: true, showsCollapsedRails: false))
                                    .layoutRole("editor-workspace")
                                    .debugName("editor-workspace")
                            }
                        }.flex().frame(minWidth: 0, minHeight: 0)

                        if surface.view == .make {
                            EditorStatusBar(app: app, controller: controller, onCommand: cb.handleMenuCommand)
                        }
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
                    EditorNotificationHost(notifications: .of(app))
                    CommandPalettePresentation(app: app, controller: controller, registry: registry,
                                               availableHeight: windowHeight)
                    if let pendingClose = store.pendingCloseRequest {
                        UnsavedChangesDialog(app: app, request: pendingClose)
                    } else if let confirmation = store.pendingConfirmationRequest {
                        ModalBarrier {
                            AgentReview(app: app, request: confirmation)
                                .padding(24).frame(width: 640).background(.surfaceFloating).cornerRadius(14)
                        }
                    }
                    if store.pluginManagement.candidate != nil {
                        LaunchPluginReview(app: app, management: store.pluginManagement)
                    }
                }
                } else {
                    LaunchSurface()
                }
            }
        }
    }
}

/// What the window paints until the editor is ready: the themed background and
/// nothing else. A view or a palette that arrives a few frames late reads as a
/// flash, so the window waits for the packages that ship with the editor to
/// register before drawing the editor it is going to keep.
private struct LaunchSurface: View {
    var body: some View {
        LayerRoot {
            Box(direction: .column, alignItems: .stretch, spacing: 0) { }
                .background(.background)
                .flex()
                .frame(minWidth: 0, minHeight: 0)
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
            let context = EditorCommandContext(app: app)
            return EditorShortcutHandler.handle(key,
                                                catalog: .make(context),
                                                commandPaletteVisible: commandPaletteVisible,
                                                closeCommandPalette: { app.store.dispatch(.setCommandPaletteVisible(false)) },
                                                perform: perform,
                                                unavailable: { entry in
                guard EditorCommandCatalog.isBlockedOnlyByPlayback(entry, in: context) else { return }
                EditorNotifications.of(app).postBlockedByPlayback(L("Stop the game to edit the scene"), app: app)
            })
        }
    }
}
