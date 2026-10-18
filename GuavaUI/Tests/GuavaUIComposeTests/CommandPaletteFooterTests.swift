import Foundation
import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("Command palette custom footer", .serialized)
struct CommandPaletteFooterTests: GuavaUIComposeSerializedSuite {
    private var items: [CommandItem] {
        [CommandItem("Toggle Theme", group: "View") {}, CommandItem("Go to File", group: "Navigate") {}]
    }

    private func nodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { nodes($0) }
    }

    private func withPalette(width: Float = 720,
                             footer: (() -> AnyView)? = nil,
                             _ run: (ViewGraph) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let context = PlatformInputContext()
            let store = PortalStore()
            context.addScopedAmbient(PortalStoreAmbient(store))
            let previousText = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previousText }
            try context.withCurrent {
                var environment = UIEnvironment()
                environment.viewport.width = width
                environment.viewport.height = 820
                environment.input = [.pointer, .keyboard]
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                var open = true
                graph.install(root: LayerRoot {
                    if let footer {
                        CommandPalette(isPresented: Binding(get: { open }, set: { open = $0 }),
                                       items: items, footer: footer)
                    } else {
                        CommandPalette(isPresented: Binding(get: { open }, set: { open = $0 }), items: items)
                    }
                }.frame(width: .points(width), height: .points(820)).surfaceEnvironment(environment))
                for _ in 0..<20 {
                    graph.recomposer.commitAll()
                    graph.computeLayout(width: width, height: 820)
                    AnimatorScheduler.current.tick(deltaTime: 0.1)
                }
                defer { graph.install(root: EmptyView()) }
                try run(graph)
            }
        }
    }

    @Test("custom footer replaces the default hints")
    func customFooter() throws {
        try withPalette(footer: {
            AnyView(Row(alignment: .center, spacing: 8) {
                Text("Aurora workspace").font(.caption)
                Spacer()
                Text("Custom footer").font(.caption)
            }
            .padding(horizontal: 14, vertical: 8)
            .debugName("test-custom-footer"))
        }) { graph in
            let footer = try #require(nodes(graph.tree.root).first {
                $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "test-custom-footer"
            })
            #expect(footer.frame.height >= 24)
            #expect(!nodes(graph.tree.root).contains {
                $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "commandPalette.footer"
            })
            #expect(nodes(graph.tree.root).contains { $0.accessibility?.label == "Aurora workspace" })
        }
    }

    @Test("the default footer remains when no custom footer is supplied")
    func defaultFooter() throws {
        try withPalette { graph in
            #expect(nodes(graph.tree.root).contains {
                $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "commandPalette.footer"
            })
        }
    }
}
