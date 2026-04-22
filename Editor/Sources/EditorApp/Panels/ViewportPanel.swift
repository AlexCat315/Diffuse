import EditorCore
import GuavaUICompose
import GuavaUIRuntime
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
                Box(direction: .column, alignItems: .stretch) {
                    Box(direction: .column, alignItems: .stretch, spacing: 4) {
                        Row(alignment: .center, spacing: 8) {
                            Text(surface.isValid
                                 ? "\(surface.width) × \(surface.height)"
                                 : "Waiting for first render packet")
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)

                            Spacer(minLength: 0)

                            if let entity {
                                Text(entity.name)
                                    .font(.caption)
                                    .foregroundColor(.onSurface)
                            }
                        }

                        Text("Passes: \(stats.passCount)  Draws: \(stats.drawCallCount)")
                            .font(.mono)
                            .foregroundColor(.onSurfaceMuted)
                    }
                    .padding(8)
                    .background(.surfaceOverlay)
                    .cornerRadius(2)
                    .border(Color(r: 1, g: 1, b: 1, a: 0.08), width: 1)

                    Box(direction: .column, alignItems: .center, justifyContent: .center) {
                        if !surface.isValid {
                            Box(direction: .column, alignItems: .center, spacing: 4) {
                                Text("Viewport idle")
                                    .font(.headline)
                                    .foregroundColor(.onSurface)

                                Text("Waiting for the first render packet from the engine.")
                                    .font(.caption)
                                    .foregroundColor(.onSurfaceVariant)
                            }
                            .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
                            .background(.surfaceRaised)
                            .cornerRadius(2)
                            .border(Color(r: 1, g: 1, b: 1, a: 0.08), width: 1)
                        } else {
                            EmptyView()
                        }
                    }
                    .flex()
                }
                .padding(10)
            }
            .flex()
            .background(.surfaceSunken)
        }
    }
}
