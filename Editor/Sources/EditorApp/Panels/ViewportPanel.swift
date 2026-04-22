import EditorCore
import GuavaUICompose

struct ViewportPanel: View {
    let app: EditorApplication

    var body: some View {
        Box(direction: .column, alignItems: .center, justifyContent: .center) {
            Text("Viewport")
                .font(.system(size: 14, weight: .semibold))
            Text("(engine framebuffer pending)")
                .font(.system(size: 11))
        }
        .flex()
    }
}
