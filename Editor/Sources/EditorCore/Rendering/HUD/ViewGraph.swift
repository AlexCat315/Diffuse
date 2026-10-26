internal import EngineKernel
internal import CoveUICompose

/// Adapts the engine's script canvas to the UI's offscreen view renderer.
final class InGameViewGraphBridge {
    private let view: OffscreenView
    private let source: InGameDrawListSource
    private let scriptCanvas = ScriptCanvasModel()
    private var didInstallRoot = false

    init(source: InGameDrawListSource) {
        self.source = source
        view = OffscreenView()
    }

    func setRootView<V: View>(_ root: V) {
        guard !didInstallRoot else { return }
        view.setRootView(Box {
            root
            ScriptCanvasView(model: scriptCanvas)
                .absolutePosition(left: 0, top: 0, right: 0, bottom: 0)
        }.flex())
        didInstallRoot = true
    }

    func tick(width: Int, height: Int, contentScale: Float = 1, canvas: InGameCanvas = InGameCanvas()) {
        scriptCanvas.update(canvas)
        if !didInstallRoot { setRootView(EmptyView()) }
        if let snapshot = view.render(width: width, height: height, contentScale: contentScale) {
            source.publish(snapshot)
        }
    }
}
