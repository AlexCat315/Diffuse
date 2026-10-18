import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Narrow disclosure headers", .serialized)
@MainActor
struct DisclosureAdaptiveTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }

    @Test("Long headers keep one line, complete semantics and keyboard activation at both text scales")
    func headers() throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let title = "Workspace permissions, collaboration and notification preferences"
            for width: Float in [390, 720, 1280] {
                for scale: Float in [1, 2] {
                    for theme in [Theme.defaultLight, Theme.defaultDark] {
                        let context = PlatformInputContext()
                        try context.withCurrent {
                            var expanded: Set<Int> = [], disclosure = false
                            var surface = UIEnvironment(); surface.viewport.width = width
                            surface.input = width == 1280 ? [.pointer, .keyboard] : [.touch, .keyboard]
                            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                            graph.install(root: Column(alignment: .leading, spacing: 20) {
                                Accordion([AccordionItem(1, title) { Text("Accordion content") }],
                                    expanded: Binding(get: { expanded }, set: { expanded = $0 }))
                                DisclosureGroup(title, isExpanded: Binding(get: { disclosure }, set: { disclosure = $0 })) {
                                    Text("Disclosure content")
                                }
                            }.frame(width: 220).surfaceEnvironment(surface).textScaler(.init(scale)).theme(theme).reducedMotion())
                            for _ in 0..<6 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 600) }
                            let all = nodes(graph.tree.root!)
                            let titles = all.filter { $0.layoutNode?.textInputs?.text == title }
                            #expect(titles.count == 2)
                            for label in titles {
                                #expect(label.frame.width > 0 && label.frame.width <= 220)
                                #expect(label.layoutNode?.textMeasure?.result.lines.count == 1)
                                #expect(label.accessibility?.label == title)
                            }
                            let headers = all.filter { $0.attachments[ButtonHost.markerKey] as? Bool == true }
                            #expect(headers.count == 2)
                            let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                capture: context.pointerCapture, focusChain: context.focusChain)
                            for header in headers {
                                if width != 1280 { #expect(header.frame.height >= 44) }
                                context.focusChain.focus(header)
                                input.dispatch(.keyDown(.init(scancode: Scancode.space, keycode: 0, modifiers: [], isRepeat: false)))
                            }
                            #expect(expanded == [1] && disclosure)
                            graph.install(root: EmptyView())
                        }
                    }
                }
            }
        }
    }
}
