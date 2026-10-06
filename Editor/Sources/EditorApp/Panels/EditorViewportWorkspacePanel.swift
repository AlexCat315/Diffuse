import EditorCore
import EngineKernel
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend

struct EditorViewportWorkspacePanel: View {
    let app: EditorApplication

    var body: some View {
        StoreScope(app.store) { store in
            Column(alignment: .leading, spacing: 0) {
                Row(alignment: .center, spacing: 8) {
                    Button(L("Scene Editing"), isSelected: store.viewportMode == .scene) { app.setViewportMode(.scene) }
                        .buttonStyle(.tab)
                    if store.workspaceMode.isGameWorkspace {
                        Button(L("Game Preview"), isSelected: store.viewportMode == .game) { app.setViewportMode(.game) }
                            .buttonStyle(.tab)
                    }
                    Spacer(minLength: 0)
                    if store.viewportMode == .game {
                        EnumField(value: Binding(get: { store.gamePreviewResolution }, set: app.setGamePreviewResolution),
                                  width: 208, label: { L($0.title) })
                        Checkbox(isOn: Binding(get: { store.gamePreviewHUDEnabled }, set: app.setGamePreviewHUDEnabled))
                        Text(L("HUD")).font(.caption)
                    }
                }.padding(horizontal: 6, vertical: 4)
                Divider()
                if store.viewportMode == .game {
                    GamePreviewPanel(app: app).flex()
                } else {
                    ViewportPanel(app: app, scene: app.scene).flex()
                }
            }.frame(minWidth: 0, minHeight: 0)
        }
    }
}

private struct GamePreviewPanel: View {
    let app: EditorApplication

    var body: some View {
        let store = app.store
        let _ = store.viewportSurfaceRevision
        Column(alignment: .leading, spacing: 0) {
            Row(alignment: .center, spacing: 8) {
                Text(store.playbackState == .stopped ? L("Preview stopped")
                    : (store.gamePreviewFocused ? L("Game has input focus · Esc to release") : L("Click the game image to focus input")))
                    .font(.caption).foregroundColor(store.gamePreviewFocused ? .accent : .onSurfaceVariant).flex()
                if store.playbackState == .stopped {
                    Button(L("Play")) { app.applyPlaybackState(.playing) }.buttonStyle(.ghost)
                }
            }.padding(6)
            ViewportHost(surface: app.currentViewportSurfaceState(),
                contentAspectRatio: store.gamePreviewResolution.aspectRatio,
                onFocusChanged: { focused in
                    if store.gamePreviewFocused != focused { store.dispatch(.setGamePreviewFocused(focused)) }
                    if !focused { app.enqueueViewportInput(.windowFocusLost) }
                },
                onInputEvent: { event in
                    if case let .keyDown(key) = event {
                        if key.scancode == Scancode.escape {
                            FocusChainHolder.current?.clear()
                            app.enqueueViewportInput(.windowFocusLost)
                            return
                        }
                        if key.modifiers.hasGui || key.modifiers.hasCtrl { return }
                    }
                    guard store.playbackState == .playing, store.gamePreviewFocused else { return }
                    if let frame = EditorViewportDropTarget.frame {
                        app.enqueueViewportInput(EditorGamePreviewInput.map(event, frame: frame,
                            resolution: store.gamePreviewResolution.size))
                    } else { app.enqueueViewportInput(event) }
                },
                onDrawableSizeChange: app.setViewportDrawableSize,
                onScreenFrameChange: { EditorViewportDropTarget.frame = $0 }) {
                    EmptyView()
                }
                .flex().background(.surfaceSunken)
        }.frame(minWidth: 0, minHeight: 0)
    }
}

enum EditorGamePreviewInput {
    /// Game input uses image-local coordinates even when the image is
    /// letterboxed, scaled or embedded beside other editor panels.
    static func map(_ event: InputEvent, frame: ViewportScreenFrame, resolution: RenderDrawableSize?) -> InputEvent {
        guard frame.width > 0, frame.height > 0 else { return event }
        let sx = resolution.map { Float($0.width) / frame.width } ?? 1
        let sy = resolution.map { Float($0.height) / frame.height } ?? 1
        switch event {
        case .mouseButtonDown(var pointer):
            pointer.x = (pointer.x - frame.x) * sx; pointer.y = (pointer.y - frame.y) * sy
            return .mouseButtonDown(pointer)
        case .mouseButtonUp(var pointer):
            pointer.x = (pointer.x - frame.x) * sx; pointer.y = (pointer.y - frame.y) * sy
            return .mouseButtonUp(pointer)
        case .mouseMotion(var pointer):
            pointer.x = (pointer.x - frame.x) * sx; pointer.y = (pointer.y - frame.y) * sy
            pointer.deltaX *= sx; pointer.deltaY *= sy
            return .mouseMotion(pointer)
        case .mouseWheel(var wheel):
            wheel.mouseX = wheel.mouseX.map { ($0 - frame.x) * sx }
            wheel.mouseY = wheel.mouseY.map { ($0 - frame.y) * sy }
            return .mouseWheel(wheel)
        default: return event
        }
    }
}
