import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 7 List & Tree", .serialized)
struct ListTreeTests: GuavaUIComposeSerializedSuite {

    struct ListItem: Identifiable {
        let id: Int
        let title: String
    }

    struct TreeItem: Identifiable {
        let id: String
        let title: String
        let children: [TreeItem]
    }

    final class Probe<Value> {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    struct ListHarness: View {
        let probe: Probe<Int?>
        let items: [ListItem]

        @State var selection: Int? = nil

        var body: some View {
            List(items,
                 selection: Binding(get: { selection },
                                    set: { newValue in
                                        selection = newValue
                                        probe.value = newValue
                                    })) { item, isSelected in
                Text(isSelected ? "selected \(item.title)" : item.title)
            }
        }
    }

    struct TreeHarness: View {
        let selectionProbe: Probe<String?>
        let expandedProbe: Probe<Set<String>>
        let roots: [TreeItem]

        @State var selection: String? = nil
        @State var expanded: Set<String> = []

        var body: some View {
            Tree(roots,
                 children: \.children,
                 selection: Binding(get: { selection },
                                    set: { newValue in
                                        selection = newValue
                                        selectionProbe.value = newValue
                                    }),
                 expanded: Binding(get: { expanded },
                                   set: { newValue in
                                       expanded = newValue
                                       expandedProbe.value = newValue
                                   })) { item, isSelected, _, depth in
                Text("\(depth): \(item.title)",
                     color: isSelected ? Color.white : Color.black)
            }
        }
    }

    @Test("List tap updates binding and selected background")
    func listSelection() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let probe = Probe<Int?>(nil)
        let items = [
            ListItem(id: 1, title: "One"),
            ListItem(id: 2, title: "Two"),
            ListItem(id: 3, title: "Three")
        ]

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: ListHarness(probe: probe, items: items))
        graph.computeLayout(width: 240, height: 160)

        var buttons = orderedPointerNodes(in: tree.root!, registry: registry)
        #expect(buttons.count == 3)

        tap(buttons[1], registry: registry)

        #expect(probe.value == 2)
        #expect(graph.recomposer.hasPending == true)

        graph.recomposer.commitAll()
        graph.computeLayout(width: 240, height: 160)

        buttons = orderedPointerNodes(in: tree.root!, registry: registry)
        // The selection fill now lives on the row style's body (one descendant
        // below the host pointer node) — walk into the styled subtree to count
        // selected backgrounds.
        let selectedRows = buttons.filter { host in
            host.children.contains { $0.backgroundColor != nil }
                || host.children.flatMap(\.children).contains { $0.backgroundColor != nil }
        }
        #expect(selectedRows.count == 1)
    } }

    @Test("Tree disclosure updates expanded binding and reveals child rows")
    func treeExpansion() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let roots = [
            TreeItem(id: "scene", title: "Scene", children: [
                TreeItem(id: "camera", title: "Camera", children: []),
                TreeItem(id: "light", title: "Light", children: [])
            ]),
            TreeItem(id: "console", title: "Console", children: [])
        ]

        let selectionProbe = Probe<String?>(nil)
        let expandedProbe = Probe<Set<String>>([])

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: TreeHarness(selectionProbe: selectionProbe,
                                        expandedProbe: expandedProbe,
                                        roots: roots))
        graph.computeLayout(width: 280, height: 220)

        var buttons = orderedPointerNodes(in: tree.root!, registry: registry)
        #expect(buttons.count == 3)

        let disclosure = buttons.min { $0.frame.width < $1.frame.width }!
        tap(disclosure, registry: registry)

        #expect(expandedProbe.value == ["scene"])
        #expect(graph.recomposer.hasPending == true)

        graph.recomposer.commitAll()
        graph.computeLayout(width: 280, height: 220)

        buttons = orderedPointerNodes(in: tree.root!, registry: registry)
        #expect(buttons.count == 5)
        #expect(buttons.contains { $0.frame.minX > disclosure.frame.maxX })
    } }

    @Test("Tree child tap updates selection binding after expansion")
    func treeSelection() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let roots = [
            TreeItem(id: "scene", title: "Scene", children: [
                TreeItem(id: "camera", title: "Camera", children: []),
                TreeItem(id: "light", title: "Light", children: [])
            ])
        ]

        let selectionProbe = Probe<String?>(nil)
        let expandedProbe = Probe<Set<String>>([])

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: TreeHarness(selectionProbe: selectionProbe,
                                        expandedProbe: expandedProbe,
                                        roots: roots))
        graph.computeLayout(width: 280, height: 220)

        var buttons = orderedPointerNodes(in: tree.root!, registry: registry)
        let disclosure = buttons.min { $0.frame.width < $1.frame.width }!
        tap(disclosure, registry: registry)
        graph.recomposer.commitAll()
        graph.computeLayout(width: 280, height: 220)

        buttons = orderedPointerNodes(in: tree.root!, registry: registry)
        let childRow = buttons.first {
            $0.frame.minX > disclosure.frame.maxX && $0.frame.width > disclosure.frame.width
        }

        #expect(childRow != nil)
        guard let childRow else { return }
        tap(childRow, registry: registry)

        #expect(selectionProbe.value == "camera")
        #expect(graph.recomposer.hasPending == true)
    } }

    @Test("Tree row hosts register hover handlers")
    func treeRowsRegisterHoverHandlers() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let roots = [
            TreeItem(id: "scene", title: "Scene", children: [
                TreeItem(id: "camera", title: "Camera", children: [])
            ]),
            TreeItem(id: "console", title: "Console", children: [])
        ]

        let selectionProbe = Probe<String?>(nil)
        let expandedProbe = Probe<Set<String>>([])

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: TreeHarness(selectionProbe: selectionProbe,
                                        expandedProbe: expandedProbe,
                                        roots: roots))
        graph.computeLayout(width: 280, height: 220)

        let buttons = orderedPointerNodes(in: tree.root!, registry: registry)
        let disclosure = buttons.min { $0.frame.width < $1.frame.width }!
        let rowHosts = buttons.filter { $0 !== disclosure }

        #expect(rowHosts.count == 2)
        #expect(rowHosts.allSatisfy { registry.handlers(for: $0).hover != nil })
    } }

    @Test("Tree guide lines use pixel-aligned 1pt strokes")
    func treeGuideLinesArePixelAligned() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let roots = [
            TreeItem(id: "scene", title: "Scene", children: [
                TreeItem(id: "group", title: "Group", children: [
                    TreeItem(id: "leaf", title: "Leaf", children: [])
                ])
            ])
        ]

        let selectionProbe = Probe<String?>(nil)
        let expandedProbe = Probe<Set<String>>(["scene", "group"])

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: TreeHarness(selectionProbe: selectionProbe,
                                        expandedProbe: expandedProbe,
                                        roots: roots))
        graph.computeLayout(width: 280, height: 220)

        // Expand root then child so guide segments are materialized.
        var buttons = orderedPointerNodes(in: tree.root!, registry: registry)
        let rootDisclosure = buttons.min { $0.frame.width < $1.frame.width }!
        tap(rootDisclosure, registry: registry)
        graph.recomposer.commitAll()
        graph.computeLayout(width: 280, height: 220)

        buttons = orderedPointerNodes(in: tree.root!, registry: registry)
        let disclosureButtons = buttons.filter { $0.frame.width == rootDisclosure.frame.width }
        #expect(disclosureButtons.count >= 2)
        tap(disclosureButtons[1], registry: registry)
        graph.recomposer.commitAll()
        graph.computeLayout(width: 280, height: 220)

        var verticalOrHorizontalStrokes: [Node] = []
        collectStrokeNodes(from: tree.root!, into: &verticalOrHorizontalStrokes)

        #expect(!verticalOrHorizontalStrokes.isEmpty)
        #expect(verticalOrHorizontalStrokes.allSatisfy { node in
            let w = node.frame.width
            let h = node.frame.height
            return (w == 1 && h >= 1) || (h == 1 && w >= 1)
        })
    } }

    private func orderedPointerNodes(in root: Node,
                                     registry: InteractionRegistry) -> [Node] {
        var out: [Node] = []
        collectPointerNodes(from: root, registry: registry, into: &out)
        return out.sorted {
            if $0.frame.minY == $1.frame.minY {
                return $0.frame.minX < $1.frame.minX
            }
            return $0.frame.minY < $1.frame.minY
        }
    }

    private func collectPointerNodes(from node: Node,
                                     registry: InteractionRegistry,
                                     into out: inout [Node]) {
        if registry.handlers(for: node).pointer != nil {
            out.append(node)
        }
        for child in node.children {
            collectPointerNodes(from: child, registry: registry, into: &out)
        }
    }

    private func tap(_ node: Node,
                     registry: InteractionRegistry) {
        let pointer = registry.handlers(for: node).pointer!
        let evt = MouseButtonEvent(button: .left,
                                   x: Float(node.frame.midX.rounded()),
                                   y: Float(node.frame.midY.rounded()),
                                   clicks: 1)
        _ = pointer(evt, .down, .target)
        _ = pointer(evt, .up, .target)
    }

    private func collectStrokeNodes(from node: Node,
                                    into out: inout [Node]) {
        let w = node.frame.width
        let h = node.frame.height
        if (w == 1 && h >= 1) || (h == 1 && w >= 1) {
            out.append(node)
        }
        for child in node.children {
            collectStrokeNodes(from: child, into: &out)
        }
    }
}