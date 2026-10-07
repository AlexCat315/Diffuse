import EditorCore
import EngineKernel
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace
import Foundation

struct EditorRootView: View {
    let app: EditorApplication
    let controller: WorkspaceController
    let registry: PanelRegistry
    @State private var windowWidth: Float = 1280
    @State private var windowHeight: Float = 720
    @State private var agentController = EditorAgentWorkspaceDefaults.makeController()

    var body: some View {
        StoreScope(app.store) { store in
            let cb = EditorCallbacks(app: app, controller: controller, registry: registry,
                                     commandPaletteVisible: store.commandPaletteVisible)
            EditorPresentationBoundary(presentation: store.presentation) {
                LayerRoot {
                    Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        ShortcutHost(onKeyDown: cb.handleShortcut)

                        ImmersiveWindowTitleBar {
                            Row(alignment: .center, spacing: 8) {
                                EditorApplicationMenuBar(
                                    workspaceMode: store.workspaceMode,
                                    activeLayoutPreset: store.activeLayoutPreset,
                                    playbackState: store.playbackState,
                                    interactionMode: store.interactionMode,
                                    canUndo: TextEditingCommands.canUndo ?? app.canUndo,
                                    canRedo: TextEditingCommands.canRedo ?? app.canRedo,
                                    hasSelection: !store.selectedEntityIDs.isEmpty,
                                    onCommand: cb.handleMenuCommand
                                )

                                Spacer(minLength: 0)
                            }
                        }

                        EditorWorkflowBar(workspace: store.workspace,
                                          playbackState: store.playbackState,
                                          onCommand: cb.handleMenuCommand)

                        if store.interactionMode == .agent {
                            AgentWorkbenchView(app: app, controller: agentController)
                                .flex().frame(minWidth: 0, minHeight: 0)
                                .padding(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                        } else {
                            PanelWorkspace(controller: controller,
                                           registry: registry, compact: windowWidth < 1000)
                                .flex()
                                .frame(minWidth: 0, minHeight: 0)
                                .workspaceTheme(WorkspaceTheme(tabBarHeight: 30, splitDividerThickness: 5))
                                .padding(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                                .layoutRole("editor-workspace")
                                .debugName("editor-workspace")
                        }

                        EditorStatusBar(store: store, scriptWorkspace: app.scriptWorkspace,
                                        showsScriptInfo: controller.document.groups.values.contains { $0.activePanelID == "scripts" && !$0.isCollapsed },
                                        onShowProblems: {
                                            store.dispatch(.setOutputTab(.problems))
                                            EditorRootViewFactory.activatePanel("console", in: controller)
                                        })
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
    let handleMenuCommand: (EditorMenuCommand) -> Void

    init(app: EditorApplication,
         controller: WorkspaceController,
         registry: PanelRegistry,
         commandPaletteVisible: Bool) {
        self.handleMenuCommand = { command in
            EditorCommandDispatcher.handle(command, app: app, controller: controller, registry: registry)
        }
        self.handleShortcut = { key in
            let s = app.store
            return EditorShortcutHandler.handle(
                key,
                playbackState: s.state.timing.playbackState,
                commandPaletteVisible: commandPaletteVisible,
                setPlaybackState: { next in
                    EditorCommandDispatcher.handle(.setPlaybackState(next),
                                                   app: app,
                                                   controller: controller,
                                                   registry: registry)
                },
                setWorkspaceMode: { next in
                    EditorCommandDispatcher.handle(.setWorkspaceMode(next),
                                                   app: app,
                                                   controller: controller,
                                                   registry: registry)
                },
                resetLayout: {
                    EditorCommandDispatcher.handle(.resetLayout,
                                                   app: app,
                                                   controller: controller,
                                                   registry: registry)
                },
                reopenClosedPanel: {
                    EditorCommandDispatcher.handle(.reopenClosedPanel,
                                                   app: app,
                                                   controller: controller,
                                                   registry: registry)
                },
                newScene: {
                    EditorCommandDispatcher.handle(.newScene, app: app, controller: controller, registry: registry)
                },
                openScene: {
                    EditorCommandDispatcher.handle(.openScene, app: app, controller: controller, registry: registry)
                },
                saveScene: {
                    EditorCommandDispatcher.handle(.saveScene, app: app, controller: controller, registry: registry)
                },
                duplicateSelection: {
                    EditorCommandDispatcher.handle(.duplicateSelection,
                                                   app: app,
                                                   controller: controller,
                                                   registry: registry)
                },
                deleteSelection: {
                    EditorCommandDispatcher.handle(.deleteSelection,
                                                   app: app,
                                                   controller: controller,
                                                   registry: registry)
                },
                buildProject: {
                    EditorCommandDispatcher.handle(.buildProject, app: app, controller: controller, registry: registry)
                },
                buildAndRun: {
                    EditorCommandDispatcher.handle(.buildAndRun, app: app, controller: controller, registry: registry)
                },
                openSettings: {
                    EditorCommandDispatcher.handle(.openSettings,
                                                   app: app,
                                                   controller: controller,
                                                   registry: registry)
                },
                openCommandPalette: {
                    s.dispatch(.setCommandPaletteQuery(">"))
                    s.dispatch(.setCommandPaletteVisible(true))
                },
                closeCommandPalette: { s.dispatch(.setCommandPaletteVisible(false)) },
                undo: {
                    EditorCommandDispatcher.handle(.undo, app: app, controller: controller, registry: registry)
                },
                redo: {
                    EditorCommandDispatcher.handle(.redo, app: app, controller: controller, registry: registry)
                },
                openResourceSearch: {
                    s.dispatch(.setCommandPaletteQuery("@"))
                    s.dispatch(.setCommandPaletteVisible(true))
                }
            )
        }
    }
}
