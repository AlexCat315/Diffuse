import EditorCore
import GuavaUI
import GuavaUIRuntime

struct ViewportNavigationSelector: View {
    let scene: EditorSceneAdapter
    @State private var isPresented = false

    var body: some View {
        Popover(isPresented: $isPresented, isEnabled: scene.isAuthoringEnabled, width: 280, placement: .bottomTrailing, surface: .content, overflow: .flip,
                onKey: viewportPopoverDismissOnEscape($isPresented)) {
            Text(L("Navigate")).font(.caption).padding(horizontal: 6).frame(height: 24)
                .background(.surface).cornerRadius(4)
                .accessibility { $0.label = L("Viewport navigation") }
        } content: {
            Column(alignment: .leading, spacing: 10) {
                Text(L("Viewport navigation")).font(.bodyStrong)
                directionRow("Orbit", id: "orbit") { horizontal, vertical in
                    scene.orbitCamera(deltaScreenX: horizontal * 20, deltaScreenY: vertical * 20, in: frame)
                }
                directionRow("Pan", id: "pan") { horizontal, vertical in
                    scene.panCamera(deltaScreenX: horizontal * 40, deltaScreenY: vertical * 40, in: frame)
                }
                Row(alignment: .center, spacing: 8) {
                    Button(L("Zoom In")) { scene.zoomCamera(factor: 0.8) }
                    Button(L("Zoom Out")) { scene.zoomCamera(factor: 1.25) }
                }
                Button(L("Reset View")) { scene.resetViewportView() }.debugName("viewport-reset-view")
                Divider()
                Text(L("Orbit: Option/Alt + drag or scroll. Pan: Shift + scroll or middle drag. Zoom: scroll. Drag the axis widget to orbit."), lineLimit: 5)
                    .font(.caption).foregroundColor(.onSurfaceMuted)
            }.padding(12).background(.surface).cornerRadius(8).border(.divider, width: 1)
                .buttonStyle(.secondary)
        }.debugName("viewport-navigation")
    }

    private var frame: ViewportScreenFrame {
        EditorViewportDropTarget.frame ?? ViewportScreenFrame(x: 0, y: 0, width: 800, height: 600)
    }

    private func directionRow(_ title: String, id: String, action: @escaping (Float, Float) -> Void) -> some View {
        Row(alignment: .center, spacing: 4) {
            Text(L(title)).font(.caption).frame(width: 48)
            Button("←") { action(-1, 0) }.debugName("viewport-\(id)-left").accessibility { $0.label = L(title) + " " + L("Left") }
            Button("↑") { action(0, -1) }.debugName("viewport-\(id)-up").accessibility { $0.label = L(title) + " " + L("Up") }
            Button("↓") { action(0, 1) }.debugName("viewport-\(id)-down").accessibility { $0.label = L(title) + " " + L("Down") }
            Button("→") { action(1, 0) }.debugName("viewport-\(id)-right").accessibility { $0.label = L(title) + " " + L("Right") }
        }
    }
}
