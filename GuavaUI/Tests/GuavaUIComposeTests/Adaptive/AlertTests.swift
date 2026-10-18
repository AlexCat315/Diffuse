import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Adaptive inline alerts", .serialized)
@MainActor
struct AlertAdaptiveTests: GuavaUIComposeSerializedSuite {
    private let title = "Reconnect to synchronize your workspace"
    private let message = "Your local changes are safe. Reconnect when the connection returns, or continue working offline."
    private func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }
    private func button(_ label: String, in graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == .button &&
            ($0.accessibility?.label == label || $0.children.contains { $0.layoutNode?.textInputs?.text == label }) })
    }

    @Test("Actions fit the actual card, preserve text alignment and retain complete semantics")
    func matrix() throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            for width: Float in [390, 720, 1280] {
                for scale: Float in [1, 2] {
                    for rtl in [false, true] {
                        for theme in [Theme.defaultLight, Theme.defaultDark] {
                            for variant: Alert<EmptyView>.Variant in [.soft, .outline, .filled] {
                                let context = PlatformInputContext()
                                try context.withCurrent {
                                    var surface = UIEnvironment(); surface.viewport.width = width
                                    surface.input = width == 1280 ? [.pointer, .keyboard] : [.touch, .keyboard]
                                    let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                                    var alert = Alert(title, message: message, tone: .warning, actions: {
                                        Button("Reconnect to workspace") {}.accessibilityLabel("Retry")
                                        Button("Continue working offline") {}.accessibilityLabel("Offline")
                                    })
                                    if variant == .outline { alert.variant = .outline }
                                    if variant == .filled { alert.variant = .filled }
                                    alert.showsIcon = variant != .outline; alert.onDismiss = {}
                                    var resolvedTheme = theme
                                    if variant == .filled { resolvedTheme.icons.scaling = .factor(1.5) }
                                    graph.install(root: alert.frame(width: width - 32).surfaceEnvironment(surface).textScaler(.init(scale))
                                        .layoutDirection(rtl ? .rtl : .ltr).theme(resolvedTheme).reducedMotion())
                                    defer { graph.install(root: EmptyView()) }
                                    for _ in 0..<5 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 1000) }
                                    let all = nodes(graph.tree.root!)
                                    let status = try #require(all.first { $0.accessibility?.role == .status })
                                    let heading = try #require(all.first { $0.layoutNode?.textInputs?.text == title })
                                    let detail = try #require(all.first { $0.layoutNode?.textInputs?.text == message })
                                    #expect(status.frame.width <= CGFloat(width - 32))
                                    #expect(status.accessibility?.label == title && status.accessibility?.help == message)
                                    if variant != .outline {
                                        let slot = try #require(graph.layoutSnapshot().first { $0.debugName == "alert-icon-slot" })
                                        #expect(slot.frame.width == CGFloat(variant == .filled ? 24 : 16 * scale))
                                        if rtl { #expect(heading.absoluteFrame.maxX <= slot.absoluteFrame.minX - CGFloat(theme.spacing.sm)) }
                                        else { #expect(heading.absoluteFrame.minX >= slot.absoluteFrame.maxX + CGFloat(theme.spacing.sm)) }
                                    }
                                    if rtl { #expect(abs(heading.absoluteFrame.maxX - detail.absoluteFrame.maxX) < 0.5) }
                                    else { #expect(abs(heading.absoluteFrame.minX - detail.absoluteFrame.minX) < 0.5) }
                                    let retry = try button("Retry", in: graph), offline = try button("Offline", in: graph)
                                    for action in [retry, offline, try button("Dismiss", in: graph)] {
                                        #expect(action.absoluteFrame.minX >= status.absoluteFrame.minX)
                                        #expect(action.absoluteFrame.maxX <= status.absoluteFrame.maxX)
                                        if width != 1280 { #expect(action.frame.height >= 44) }
                                    }
                                    let stacks = offline.absoluteFrame.minY >= retry.absoluteFrame.maxY
                                    if width == 390 { #expect(stacks) }
                                    if width == 1280 || (width == 720 && scale == 1) { #expect(!stacks) }
                                    #expect(stacks || abs(offline.absoluteFrame.minY - retry.absoluteFrame.minY) < 0.5)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("Embedded card resizing repositions the same focused actions and keeps their callbacks")
    func retainedActions() throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext()
            try context.withCurrent {
                var retries = 0, dismissals = 0
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: Alert(title, message: message) { $0.onDismiss = { dismissals += 1 } } actions: {
                    Button("Reconnect to workspace") { retries += 1 }.accessibilityLabel("Retry")
                    Button("Continue working offline") {}.accessibilityLabel("Offline")
                })
                defer { graph.install(root: EmptyView()) }
                func settle(_ width: Float) { for _ in 0..<5 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 800) } }
                settle(720)
                let retry = try button("Retry", in: graph)
                context.focusChain.focus(retry)
                for width: Float in [320, 720] {
                    settle(width)
                    #expect(try button("Retry", in: graph) === retry)
                    #expect(context.focusChain.focused === retry)
                    let offline = try button("Offline", in: graph)
                    #expect((offline.absoluteFrame.minY >= retry.absoluteFrame.maxY) == (width == 320))
                }
                let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                input.dispatch(.keyDown(.init(scancode: Scancode.return, keycode: 0, modifiers: [], isRepeat: false)))
                input.dispatch(.keyUp(.init(scancode: Scancode.return, keycode: 0, modifiers: [], isRepeat: false)))
                #expect(retries == 1 && dismissals == 0)
                context.focusChain.focus(try button("Dismiss", in: graph))
                input.dispatch(.keyDown(.init(scancode: Scancode.return, keycode: 0, modifiers: [], isRepeat: false)))
                input.dispatch(.keyUp(.init(scancode: Scancode.return, keycode: 0, modifiers: [], isRepeat: false)))
                #expect(retries == 1 && dismissals == 1)
            }
        }
    }
}
