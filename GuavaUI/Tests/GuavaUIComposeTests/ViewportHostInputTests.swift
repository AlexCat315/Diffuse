import Testing
import EngineKernel
import GuavaUIRuntime
import RenderBackend
@testable import GuavaUICompose

@Suite("ViewportHost Input", .serialized)
struct ViewportHostInputTests: GuavaUIComposeSerializedSuite {
    @Test("Overlay controls receive pointer events without forwarding them to viewport input")
    func overlayControlDoesNotTriggerViewportInput() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        let capture = PointerCapture()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        FocusChainHolder.current = focus
        PointerCaptureHolder.current = capture
        defer {
            InteractionRegistryHolder.current = nil
            FocusChainHolder.current = nil
            PointerCaptureHolder.current = nil
        }

        var viewportEvents: [InputEvent] = []
        var buttonTaps = 0
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            ViewportHost(surface: ViewportSurfaceState(surfaceID: 1,
                                                       handle: 1,
                                                       width: 200,
                                                       height: 120),
                         onInputEvent: { viewportEvents.append($0) }) {
                Button(action: { buttonTaps += 1 }) {
                    Text("Rotate")
                }
                .frame(width: 80, height: 28)
            }
            .frame(width: 200, height: 120)
        )
        graph.computeLayout(width: 200, height: 120)

        let dispatcher = EventDispatcher(tree: tree,
                                         interactions: registry,
                                         capture: capture,
                                         focusChain: focus)
        let event = MouseButtonEvent(button: .left, x: 12, y: 12, clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(event))
        dispatcher.dispatch(.mouseButtonUp(event))

        #expect(buttonTaps == 1)
        #expect(viewportEvents.isEmpty)
    } }
}
