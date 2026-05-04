import Testing
import CoreGraphics
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

    struct DropEvent: Equatable {
        let sourceID: String
        let targetID: String
        let sourceTitle: String
        let targetTitle: String
        let position: TreeDropPosition
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

    struct MultiTreeHarness: View {
        let selectionProbe: Probe<String?>
        let multiSelectionProbe: Probe<Set<String>>
        let roots: [TreeItem]

        @State var selection: String? = nil
        @State var multiSelection: Set<String> = []

        var body: some View {
            Tree(roots,
                 children: \.children,
                 selection: Binding(get: { selection },
                                    set: { next in
                                        selection = next
                                        selectionProbe.value = next
                                    }),
                 multiSelection: Binding(get: { multiSelection },
                                         set: { next in
                                             multiSelection = next
                                             multiSelectionProbe.value = next
                                         })) { item, isSelected, _, depth in
                Text("\(depth): \(item.title)",
                     color: isSelected ? Color.white : Color.black)
            }
        }
    }

    struct KeyedTreeHarness: View {
        let selectionKeyProbe: Probe<TreeNodeKey<String>?>
        let multiSelectionKeyProbe: Probe<Set<TreeNodeKey<String>>>
        let roots: [TreeItem]

        @State var selectionKey: TreeNodeKey<String>? = nil
        @State var multiSelectionKeys: Set<TreeNodeKey<String>> = []

        var body: some View {
            Tree(roots,
                  children: \.children,
                 selectionKey: Binding(get: { selectionKey },
                                       set: { next in
                                           selectionKey = next
                                           selectionKeyProbe.value = next
                                       }),
                 multiSelectionKeys: Binding(get: { multiSelectionKeys },
                                             set: { next in
                                                 multiSelectionKeys = next
                                                 multiSelectionKeyProbe.value = next
                                             })) { item, isSelected, _, depth in
                Text("\(depth): \(item.title)",
                     color: isSelected ? Color.white : Color.black)
            }
        }
    }

    struct DragTreeHarness: View {
        let dropProbe: Probe<DropEvent?>
        let roots: [TreeItem]

        var body: some View {
            Tree(roots,
                 children: \.children,
                 canDrop: { _, _, _ in true },
                 onDrop: { source, target, position in
                     dropProbe.value = DropEvent(sourceID: source.id,
                                                 targetID: target.id,
                                                 sourceTitle: source.title,
                                                 targetTitle: target.title,
                                                 position: position)
                 }) { item, _, _, depth in
                Text("\(depth): \(item.title)")
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

    @Test("Tree multi-selection click also updates the primary selection binding")
    func treeMultiSelectionUpdatesPrimarySelection() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let roots = [
            TreeItem(id: "camera", title: "Camera", children: []),
            TreeItem(id: "light", title: "Light", children: []),
            TreeItem(id: "mesh", title: "Mesh", children: [])
        ]

        let selectionProbe = Probe<String?>(nil)
        let multiSelectionProbe = Probe<Set<String>>([])

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: MultiTreeHarness(selectionProbe: selectionProbe,
                                             multiSelectionProbe: multiSelectionProbe,
                                             roots: roots))
        graph.computeLayout(width: 280, height: 220)

        let rows = orderedPointerNodes(in: tree.root!, registry: registry)
        #expect(rows.count == 3)
        tap(rows[1], registry: registry)

        #expect(selectionProbe.value == "light")
        #expect(multiSelectionProbe.value == ["light"])
    } }

    @Test("Tree primary-toggle deselect keeps remaining primary selection")
    func treeMultiSelectionToggleOffDoesNotReselectRemovedItem() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let roots = [
            TreeItem(id: "camera", title: "Camera", children: []),
            TreeItem(id: "light", title: "Light", children: []),
            TreeItem(id: "mesh", title: "Mesh", children: [])
        ]

        let selectionProbe = Probe<String?>(nil)
        let multiSelectionProbe = Probe<Set<String>>([])

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: MultiTreeHarness(selectionProbe: selectionProbe,
                                             multiSelectionProbe: multiSelectionProbe,
                                             roots: roots))
        graph.computeLayout(width: 280, height: 220)

        let rows = orderedPointerNodes(in: tree.root!, registry: registry)
        #expect(rows.count == 3)

        tap(rows[0], registry: registry)
        tap(rows[1], modifiers: .gui, registry: registry)
        #expect(multiSelectionProbe.value == ["camera", "light"])
        #expect(selectionProbe.value == "light")

        tap(rows[1], modifiers: .gui, registry: registry)
        #expect(multiSelectionProbe.value == ["camera"])
        #expect(selectionProbe.value == "camera")
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

    @Test("Tree drag dispatches inside-drop callback")
    func treeDragDispatchesInsideDrop() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        let capture = PointerCapture()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = capture
        defer { PointerCaptureHolder.current = nil }

        let roots = [
            TreeItem(id: "a", title: "A", children: []),
            TreeItem(id: "b", title: "B", children: [])
        ]
        let dropProbe = Probe<DropEvent?>(nil)

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DragTreeHarness(dropProbe: dropProbe,
                                            roots: roots))
        graph.computeLayout(width: 280, height: 160)

        let rows = orderedPointerNodes(in: tree.root!, registry: registry)
        #expect(rows.count == 2)

        drag(rows[1], to: rows[0], registry: registry)

        #expect(dropProbe.value == DropEvent(sourceID: "b",
                                             targetID: "a",
                                             sourceTitle: "B",
                                             targetTitle: "A",
                                             position: .inside))
    } }

    @Test("Tree drag resolves duplicate IDs by row token")
    func treeDragWithDuplicateIDsIsDeterministic() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        let capture = PointerCapture()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = capture
        defer { PointerCaptureHolder.current = nil }

        let roots = [
            TreeItem(id: "dup", title: "First", children: []),
            TreeItem(id: "dup", title: "Second", children: [])
        ]
        let dropProbe = Probe<DropEvent?>(nil)

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DragTreeHarness(dropProbe: dropProbe,
                                            roots: roots))
        graph.computeLayout(width: 280, height: 160)

        let rows = orderedPointerNodes(in: tree.root!, registry: registry)
        #expect(rows.count == 2)

        drag(rows[1], to: rows[0], registry: registry)

        #expect(dropProbe.value == DropEvent(sourceID: "dup",
                                             targetID: "dup",
                                             sourceTitle: "Second",
                                             targetTitle: "First",
                                             position: .inside))
    } }

    @Test("TreeNodeKey selection disambiguates duplicate IDs")
    func treeNodeKeySelectionDisambiguatesDuplicateIDs() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let roots = [
            TreeItem(id: "dup", title: "First", children: []),
            TreeItem(id: "dup", title: "Second", children: [])
        ]

        let selectionKeyProbe = Probe<TreeNodeKey<String>?>(nil)
        let multiSelectionKeyProbe = Probe<Set<TreeNodeKey<String>>>([])

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: KeyedTreeHarness(selectionKeyProbe: selectionKeyProbe,
                                             multiSelectionKeyProbe: multiSelectionKeyProbe,
                                             roots: roots))
        graph.computeLayout(width: 280, height: 220)

        let rows = orderedPointerNodes(in: tree.root!, registry: registry)
        #expect(rows.count == 2)

        tap(rows[1], registry: registry)
        #expect(selectionKeyProbe.value == TreeNodeKey(id: "dup", path: [1]))
        #expect(multiSelectionKeyProbe.value == [TreeNodeKey(id: "dup", path: [1])])

        tap(rows[0], modifiers: .gui, registry: registry)
        #expect(multiSelectionKeyProbe.value == [TreeNodeKey(id: "dup", path: [0]),
                                                TreeNodeKey(id: "dup", path: [1])])
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

        var guideNodes: [Node] = []
        collectGuideNodes(from: tree.root!, into: &guideNodes)

        let strokeRects = guideNodes.flatMap(renderedGuideStrokeRects)
        #expect(!strokeRects.isEmpty)
        #expect(strokeRects.allSatisfy { rect in
            (rect.width == 1 && rect.height >= 1) || (rect.height == 1 && rect.width >= 1)
        })
    } }

    @Test("Tree guide lines keep ancestor continuation stems")
    func treeGuideLinesIncludeAncestorContinuations() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let roots = [
            TreeItem(id: "scene", title: "Scene", children: [
                TreeItem(id: "group", title: "Group", children: [
                    TreeItem(id: "leaf", title: "Leaf", children: [])
                ])
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

        var guideNodes: [Node] = []
        collectGuideNodes(from: tree.root!, into: &guideNodes)

        let strokeRects = guideNodes.flatMap(renderedGuideStrokeRects)
        #expect(strokeRects.contains { $0.width == 1 && $0.height == 30 })
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
        let handlers = registry.handlers(for: node)
        if handlers.pointer != nil, handlers.wheel == nil {
            out.append(node)
        }
        for child in node.children {
            collectPointerNodes(from: child, registry: registry, into: &out)
        }
    }

    private func tap(_ node: Node,
                     registry: InteractionRegistry) {
        tap(node, modifiers: [], registry: registry)
    }

    private func tap(_ node: Node,
                     modifiers: KeyModifiers,
                     registry: InteractionRegistry) {
        let pointer = registry.handlers(for: node).pointer!
        let evt = MouseButtonEvent(button: .left,
                                   x: Float(node.frame.midX.rounded()),
                                   y: Float(node.frame.midY.rounded()),
                                   clicks: 1,
                                   modifiers: modifiers)
        _ = pointer(evt, .down, .target)
        _ = pointer(evt, .up, .target)
    }

    private func drag(_ source: Node,
                      to target: Node,
                      registry: InteractionRegistry) {
        let pointer = registry.handlers(for: source).pointer!
        let motion = registry.handlers(for: source).motion!
        let sourceFrame = absoluteFrame(of: source)
        let targetFrame = absoluteFrame(of: target)
        let down = MouseButtonEvent(button: .left,
                                    x: Float(sourceFrame.midX.rounded()),
                                    y: Float(sourceFrame.midY.rounded()),
                                    clicks: 1)
        _ = pointer(down, .down, .target)

        let move = MouseMotionEvent(x: Float(targetFrame.midX.rounded()),
                                    y: Float(targetFrame.midY.rounded()),
                                    deltaX: Float((targetFrame.midX - sourceFrame.midX).rounded()),
                                    deltaY: Float((targetFrame.midY - sourceFrame.midY).rounded()))
        _ = motion(move, .target)

        let up = MouseButtonEvent(button: .left,
                                  x: Float(targetFrame.midX.rounded()),
                                  y: Float(targetFrame.midY.rounded()),
                                  clicks: 1)
        _ = pointer(up, .up, .target)
    }

    private func absoluteFrame(of node: Node) -> CGRect {
        var origin = node.frame.origin
        var parent = node.parent
        while let current = parent {
            origin.x += current.frame.origin.x - current.contentOffset.x
            origin.y += current.frame.origin.y - current.contentOffset.y
            parent = current.parent
        }
        return CGRect(origin: origin, size: node.frame.size)
    }

    private func collectGuideNodes(from node: Node,
                                   into out: inout [Node]) {
        if node.attachments["__tree_guide"] as? Bool == true {
            out.append(node)
        }
        for child in node.children {
            collectGuideNodes(from: child, into: &out)
        }
    }

    private func renderedGuideStrokeRects(_ node: Node) -> [UIRect] {
        let list = DrawList()
        node.draw?(list, node.frame.origin)
        var rects: [UIRect] = []
        for start in stride(from: 0, to: list.vertices.count, by: 4) {
            guard start + 3 < list.vertices.count else { continue }
            let vertices = list.vertices[start..<(start + 4)]
            let minX = vertices.map(\.posX).min() ?? 0
            let maxX = vertices.map(\.posX).max() ?? 0
            let minY = vertices.map(\.posY).min() ?? 0
            let maxY = vertices.map(\.posY).max() ?? 0
            rects.append(UIRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        }
        return rects
    }
}
