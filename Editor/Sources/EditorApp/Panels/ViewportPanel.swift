import EditorCore
import GuavaUICompose
import RenderBackend

struct ViewportPanel: View {
    let app: EditorApplication
    let scene: EditorSceneAdapter

    var body: some View {
        StoreScope(app.store) { store in
            let surface = app.currentViewportSurfaceState()
            let stats = app.currentRenderStats()
            let entity = scene.entitySummary(id: store.state.selectedEntityID)

            ViewportHost(surface: surface,
                         onInputEvent: { app.enqueueViewportInput($0) },
                         onDrawableSizeChange: { app.setViewportDrawableSize($0) }) {
                Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    Text("Scene View")
                        .font(.headline)
                    Text(surface.isValid
                         ? "\(surface.width) × \(surface.height) framebuffer"
                         : "Waiting for first render packet")
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    Text("Passes: \(stats.passCount)  Draws: \(stats.drawCallCount)")
                        .font(.mono)
                        .foregroundColor(.onSurfaceMuted)
                    if let entity {
                        Text("Focus: \(entity.name)")
                            .font(.label)
                            .foregroundColor(.accent)
                    }
                    Box { EmptyView() }
                        .flex()
                }
                .padding(12)
            }
            .flex()
            .background(.surfaceSunken)
        }
    }
}
