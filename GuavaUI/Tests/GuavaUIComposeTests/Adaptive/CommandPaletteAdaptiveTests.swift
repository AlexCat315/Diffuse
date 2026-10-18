import Foundation
import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("Command palette adaptive geometry", .serialized)
struct CommandPaletteAdaptiveTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { nodes($0) }
    }

    private var items: [CommandItem] {
        [
            CommandItem("Toggle Theme", group: "View") {},
            CommandItem("Go to File", group: "Navigate") {},
            CommandItem("Go to Line", group: "Navigate") {},
            CommandItem("Format Document", group: "Edit") {}
        ]
    }

    private func withPalette(width: Float, height: Float, input: UIEnvironment.Input,
                             _ body: (ViewGraph) throws -> Void) rethrows {
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
                environment.viewport.height = height
                environment.input = input
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                var open = true
                graph.install(root: LayerRoot {
                    CommandPalette(isPresented: Binding(get: { open }, set: { open = $0 }), items: items)
                }.frame(width: .points(width), height: .points(height)).surfaceEnvironment(environment))
                for _ in 0..<20 {
                    graph.recomposer.commitAll()
                    graph.computeLayout(width: width, height: height)
                    AnimatorScheduler.current.tick(deltaTime: 0.1)
                }
                defer { graph.install(root: EmptyView()) }
                try body(graph)
            }
        }
    }

    private func panel(_ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first {
            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "commandPalette.panel"
        })
    }

    private func button(_ label: String, _ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first {
            $0.attachments[ButtonHost.markerKey] as? Bool == true && $0.accessibility?.label == label
        })
    }

    @Test("Compact palette uses a 16pt inset and 44pt result rows")
    func compact() throws {
        try withPalette(width: 390, height: 820, input: [.touch, .keyboard]) { graph in
            let panel = try panel(graph)
            #expect(abs(panel.frame.width - 374) < 1)
            #expect(abs(panel.frame.height - 560) < 1)
            #expect(panel.absoluteFrame.minX >= 8 && panel.absoluteFrame.maxX <= 382)
            #expect(panel.absoluteFrame.minY >= 8 && panel.absoluteFrame.maxY <= 812)
            let row = try button("Toggle Theme", graph)
            #expect(row.frame.height == 44)
            let header = try #require(nodes(graph.tree.root).first {
                $0.accessibility?.role == .staticText && $0.accessibility?.label == "View"
            })
            #expect(header.frame.height == 36)
            #expect(nodes(graph.tree.root).contains { $0.accessibility?.label == "Format Document" })
        }
    }

    @Test("Regular palette keeps the 640x560 desktop geometry and 40pt rows")
    func regular() throws {
        try withPalette(width: 1280, height: 820, input: [.pointer, .keyboard]) { graph in
            let panel = try panel(graph)
            #expect(abs(panel.frame.width - 640) < 1)
            #expect(abs(panel.frame.height - 560) < 1)
            let row = try button("Toggle Theme", graph)
            #expect(row.frame.height == 40)
        }
    }
}
