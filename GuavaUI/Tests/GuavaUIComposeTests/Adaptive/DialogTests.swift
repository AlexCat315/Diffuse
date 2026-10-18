import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Adaptive dialog", .serialized)
@MainActor
struct DialogAdaptiveTests: GuavaUIComposeSerializedSuite {
    private struct Harness: View {
        @State var width: Float = 720
        @State var text: TextBuffer = "Draft"
        var body: some View {
            var surface = UIEnvironment()
            surface.viewport.width = width; surface.viewport.height = 820
            surface.input = [.touch, .pointer, .keyboard]
            return LayerRoot {
                Dialog(isPresented: .constant(true), title: "Retained dialog") {
                    TextField("Draft", text: $text)
                } footer: {
                    Button("Cancel") {}
                    Button("Save") {}
                }
            }.frame(width: width, height: 820).surfaceEnvironment(surface).reducedMotion()
        }
    }
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    @Test("Resizing preserves the action nodes, editing draft and focused field")
    func retention() throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext()
            context.addScopedAmbient(PortalStoreAmbient(PortalStore()))
            try context.withCurrent {
                let harness = Harness()
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: harness)
                func settle() {
                    for _ in 0..<12 {
                        graph.recomposer.commitAll(); graph.computeLayout(width: harness.width, height: 820)
                    }
                }
                settle()
                let field = try #require(nodes(graph.tree.root).first { $0.accessibility?.role == .textField && $0.isFocusable })
                context.focusChain.focus(field)
                harness.$text.wrappedValue = "Edited draft"
                let actions = nodes(graph.tree.root).filter { $0.attachments[ButtonHost.markerKey] as? Bool == true }.map(\.id)
                for width: Float in [390, 1280, 720] {
                    harness.$width.wrappedValue = width
                    settle()
                    #expect(context.focusChain.focused === field)
                    #expect(harness.text.stringValue == "Edited draft")
                    #expect(nodes(graph.tree.root).filter { $0.attachments[ButtonHost.markerKey] as? Bool == true }.map(\.id) == actions)
                }
                graph.install(root: EmptyView())
            }
        }
    }

    @Test("Dialogs fit compact windows and stack the same accessible actions")
    func matrix() throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            for width: Float in [390, 720, 1280] {
                for scale: Float in [1, 2] {
                    for appearance: Appearance in [.light, .dark] {
                        let context = PlatformInputContext()
                        context.addScopedAmbient(PortalStoreAmbient(PortalStore()))
                        try context.withCurrent {
                            var surface = UIEnvironment()
                            surface.viewport.width = width; surface.viewport.height = 820
                            surface.input = width == 390 ? [.touch] : width == 720 ? [.touch, .pointer, .keyboard] : [.pointer, .keyboard]
                            var open = true, confirmations = 0
                            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                            graph.install(root: LayerRoot {
                                AlertDialog(isPresented: Binding(get: { open }, set: { open = $0 }),
                                    title: "Delete project?", message: "This removes the selected project from the workspace.") {
                                    confirmations += 1
                                }
                            }.frame(width: .points(width), height: .points(820)).surfaceEnvironment(surface)
                                .textScaler(.init(scale)).appearance(appearance).reducedMotion())
                            for _ in 0..<10 {
                                graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 820)
                                AnimatorScheduler.current.tick(deltaTime: 0.1)
                            }
                            let all = nodes(graph.tree.root)
                            let panel = try #require(all.first { $0.accessibility?.role == .dialog && $0.accessibility?.label == "Delete project?" })
                            #expect(abs(panel.frame.width - CGFloat(width == 390 ? 374 : 420)) < 1)
                            let cancel = try #require(all.first { $0.attachments[ButtonHost.markerKey] as? Bool == true && nodes($0).contains { $0.layoutNode?.textInputs?.text == "Cancel" } })
                            let confirm = try #require(all.first { $0.attachments[ButtonHost.markerKey] as? Bool == true && nodes($0).contains { $0.layoutNode?.textInputs?.text == "Confirm" } })
                            for (button, title) in [(cancel, "Cancel"), (confirm, "Confirm")] {
                                let label = try #require(nodes(button).first { $0.layoutNode?.textInputs?.text == title })
                                #expect(label.layoutNode?.textMeasure?.key.text == title)
                            }
                            if width == 390 {
                                #expect(confirm.absoluteFrame.minY >= cancel.absoluteFrame.maxY)
                                #expect(cancel.frame.height >= 44 && confirm.frame.height >= 44)
                            } else {
                                #expect(abs(cancel.absoluteFrame.minY - confirm.absoluteFrame.minY) < 1)
                            }
                            #expect(confirm.absoluteFrame.maxY <= panel.absoluteFrame.maxY)
                            let message = try #require(all.first { $0.layoutNode?.textInputs?.text.hasPrefix("This removes") == true })
                            #expect(message.frame.height > 0)
                            #expect(message.absoluteFrame.maxY <= cancel.absoluteFrame.minY)
                            for node in all { #expect(node.frame.width.isFinite && node.frame.height.isFinite) }
                            confirm.accessibilityActions.activate?()
                            confirm.accessibilityActions.activate?()
                            #expect(confirmations == 1 && !open)
                            graph.install(root: EmptyView())
                        }
                    }
                }
            }
        }
    }
}
