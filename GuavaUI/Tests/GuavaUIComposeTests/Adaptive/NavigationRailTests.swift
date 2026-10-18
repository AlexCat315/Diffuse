import Foundation
import GuavaUIAgent
import GuavaUIRuntime
import Testing

@testable import GuavaUICompose

@Suite("Navigation rail", .serialized)
@MainActor
struct NavigationRailTests: GuavaUIComposeSerializedSuite {
    private struct Header: View {
        @State private var count = 0
        var body: some View {
            Button("H \(count)") { count += 1 }.buttonStyle(.ghost)
                .accessibilityLabel("Header action \(count)").frame(minWidth: 44, minHeight: 44)
                .debugName("rail-header")
        }
    }
    private final class Harness: View {
        let facade: Bool
        @State var presentation = SidebarPresentation.rail(showsLabels: true)
        @State var selected: Int? = 29
        @State var width: Float = 720
        @State var scale: Float = 1
        @State var dark = false
        @State var input: UIEnvironment.Input = [.pointer, .keyboard]
        @State var enabled = true
        @State var activations = 0
        init(facade: Bool) { self.facade = facade }
        var items: [SidebarItem<Int>] {
            (0..<30).map { index in
                SidebarItem(index, index == 4 ? "NotificationsAndWorkspacePermissions" : "Destination \(index)") {
                    $0.icon = index == 3 ? nil : UIIcons.File.folder
                    $0.iconSize = index == 5 ? .init { _ in 400 } : .medium
                    $0.badge = index == 5 ? "123456" : nil
                    $0.isEnabled = enabled && index != 2
                }
            }
        }
        var body: some View {
            var surface = UIEnvironment()
            surface.viewport.width = width
            surface.input = input
            return LayerRoot {
                Box(direction: .row, alignItems: .stretch) {
                    Box(direction: .column, alignItems: .stretch) {
                        navigation.flex(1, shrink: 1, basis: 0)
                    }.frame(width: !facade && !presentation.isRail ? .points(240) : .auto).flex(0, shrink: 0)
                        .debugName("rail-navigation")
                    Box {}.flex(1, shrink: 1, basis: 0).debugName("rail-content")
                }.flex(1, shrink: 1, basis: 0)
            }.frame(width: width, height: 420).surfaceEnvironment(surface)
                .textScaler(.init(scale)).appearance(dark ? .dark : .light).reducedMotion()
        }
        @ViewBuilder private var navigation: some View {
            if facade {
                NavigationRail(
                    selection: $selected, items: items, showsLabels: presentation.showsLabels,
                    onActivate: { _ in self.activations += 1 }, header: { Header() },
                    footer: { Text("End").font(.caption) })
            } else {
                Sidebar(
                    selection: $selected, sections: [SidebarSection("main", title: "Workspace", items: items)],
                    presentation: presentation, onActivate: { _ in self.activations += 1 },
                    header: { Header() }, footer: { Text("End").font(.caption) })
            }
        }
    }
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }
    private func named(_ name: String, _ graph: ViewGraph) throws -> Node {
        try #require(
            nodes(graph.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name })
    }
    private func row(_ id: Int, _ graph: ViewGraph) throws -> Node { try named("sidebar-item-\(id)", graph) }
    private func settle(_ graph: ViewGraph, _ harness: Harness) {
        for _ in 0..<8 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: harness.width, height: 420)
        }
    }
    private func scene(
        facade: Bool = false,
        _ work: (Harness, ViewGraph, PlatformInputContext, EventDispatcher, AnimatorScheduler, PortalStore) throws ->
            Void
    ) rethrows {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext()
            let scheduler = AnimatorScheduler()
            let portals = PortalStore()
            context.addScopedAmbient(PortalStoreAmbient(portals))
            try context.withCurrent {
                try AnimatorScheduler.$current.withValue(scheduler) {
                    let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                    let harness = Harness(facade: facade)
                    let input = EventDispatcher(
                        tree: graph.tree, interactions: context.interactions,
                        capture: context.pointerCapture, focusChain: context.focusChain)
                    graph.install(root: harness)
                    settle(graph, harness)
                    defer {
                        graph.install(root: EmptyView())
                        scheduler.reset()
                    }
                    try work(harness, graph, context, input, scheduler, portals)
                }
            }
        }
    }
    private func key(_ code: UInt32, _ input: EventDispatcher, modifiers: KeyModifiers = []) {
        input.dispatch(.keyDown(KeyEvent(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)))
    }

    @Test(
        "Rail widths, targets, text wrapping, icon clamping and names hold across theme, density and 200 percent text")
    func geometry() throws {
        try scene(facade: true) { harness, graph, _, _, _, _ in
            let retained = try row(0, graph)
            let diagnostics = UIDiagnostics(tree: graph.tree)
            for scale: Float in [1, 2] {
                for input: UIEnvironment.Input in [[.pointer, .keyboard], [.touch], [.touch, .pointer, .keyboard]] {
                    for dark in [false, true] {
                        for labels in [true, false] {
                            for width: Float in [390, 720, 1280] {
                                harness.width = width
                                harness.scale = scale
                                harness.input = input
                                harness.dark = dark
                                harness.presentation = .rail(showsLabels: labels)
                                settle(graph, harness)
                                let railWidth: CGFloat = labels ? 72 : 56
                                #expect(try named("rail-navigation", graph).frame.width == railWidth)
                                #expect(retained.id == (try row(0, graph)).id)
                                let current = try row(5, graph)
                                #expect(
                                    current.frame.width == railWidth && current.frame.height >= 44,
                                    "scale \(scale), labels \(labels), input \(input), frame \(current.frame)")
                                #expect(
                                    current.accessibility?.label == "Destination 5"
                                        && current.accessibility?.value == "123456")
                                #expect(current.accessibility?.help == "Destination 5 (123456)")
                                let glyph = try #require(
                                    nodes(current).first { $0.viewTag?.contains(".Image") == true })
                                #expect(glyph.frame.width <= railWidth - 16)
                                #expect(glyph.absoluteFrame.minX >= 0 && glyph.absoluteFrame.maxX <= railWidth)
                                let title = nodes(try row(4, graph)).first {
                                    $0.layoutNode?.textInputs?.text == "NotificationsAndWorkspacePermissions"
                                }
                                if labels {
                                    let text = try #require(title)
                                    let layout = try #require(text.layoutNode?.textMeasure as? TextLayoutCacheEntry)
                                    #expect(text.frame.width > 0 && text.absoluteFrame.maxX <= railWidth)
                                    #expect(layout.result.lines.count > 1)
                                    #expect(layout.result.lines.allSatisfy { $0.width <= Float(text.frame.width) + 1 })
                                } else {
                                    #expect(title == nil)
                                }
                                let reported = try diagnostics.queryNodes(
                                    text: "NotificationsAndWorkspacePermissions", role: "button")
                                #expect(
                                    reported.total == 1
                                        && reported.items.first?.semantics?.label
                                            == "NotificationsAndWorkspacePermissions"
                                )
                                #expect(!graph.recomposer.hasPending)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test(
        "Full, labeled and icon-only presentations retain destination identity, local header state, focus and selected visibility"
    )
    func modeRetention() throws {
        try scene { harness, graph, context, _, _, _ in
            let header = try named("rail-header", graph)
            let selected = try row(29, graph)
            header.accessibilityActions.activate?()
            settle(graph, harness)
            context.focusChain.focus(selected)
            let diagnostics = UIDiagnostics(tree: graph.tree)
            for mode: SidebarPresentation in [
                .expanded, .rail(showsLabels: false), .rail(showsLabels: true), .expanded, .rail(showsLabels: true),
                .rail(showsLabels: false),
            ] {
                harness.presentation = mode
                settle(graph, harness)
                let current = try row(29, graph)
                let currentHeader = try named("rail-header", graph)
                #expect(selected.id == current.id && context.focusChain.focused?.id == selected.id)
                #expect(header.id == currentHeader.id && header.accessibility?.label == "Header action 1")
                #expect(try named("rail-navigation", graph).frame.width == CGFloat(mode.railWidth ?? 240))
                let reported = try #require(
                    diagnostics.queryNodes(text: "Destination 29", role: "button", visibleOnly: true).items.first,
                    "mode \(mode), selected \(selected.absoluteFrame)")
                #expect((reported.presentation.visibleFrame?.h ?? 0) >= Double(selected.frame.height) - 1)
                #expect(harness.selected == 29 && harness.activations == 0)
            }
            let scroll = try #require(nodes(graph.tree.root).first { $0.attachments[ScrollReveal.handlerKey] != nil })
            scroll.contentOffset = .zero
            settle(graph, harness)
            #expect(scroll.contentOffset.y == 0, "Ordinary scrolling must not be pulled back to selection")
        }
    }

    @Test(
        "Vertical roving navigation skips disabled items, wraps, reveals targets and separates browsing from activation"
    )
    func keyboard() throws {
        try scene { harness, graph, context, input, _, _ in
            context.focusChain.focus(try row(29, graph))
            key(Scancode.home, input)
            key(Scancode.arrowDown, input)
            key(Scancode.arrowDown, input)
            settle(graph, harness)
            let third = try row(3, graph)
            #expect(harness.selected == 3 && context.focusChain.focused?.id == third.id)
            #expect(harness.activations == 0)
            key(Scancode.arrowRight, input)
            key(Scancode.arrowDown, input, modifiers: [.lshift])
            settle(graph, harness)
            #expect(harness.selected == 3)
            key(Scancode.return, input)
            settle(graph, harness)
            #expect(harness.activations == 1)
            key(Scancode.end, input)
            key(Scancode.arrowDown, input)
            settle(graph, harness)
            #expect(harness.selected == 0)
            #expect(nodes(graph.tree.root).filter { $0.attachments["__roving.item"] != nil && $0.isTabStop }.count == 1)
            let selected = try row(0, graph)
            #expect(nodes(selected).allSatisfy {
                ($0.attachments[LayoutDebugAttachmentKey.debugName] as? String) != "rail-selection-indicator"
            })
            #expect(nodes(selected).allSatisfy {
                ($0.attachments[LayoutDebugAttachmentKey.debugName] as? String) != "rail-selection-tile"
            })
        }
    }

    @Test(
        "Icon-only rail centers a 40pt selection tile on the row, drops the accent lane, and lightens the glyph on hover"
    )
    func iconTile() throws {
        try scene { harness, graph, _, input, _, _ in
            harness.dark = true
            harness.presentation = .rail(showsLabels: false)
            harness.selected = 0
            settle(graph, harness)

            let selected = try row(0, graph)
            let theme = selected.theme
            let tile = try #require(nodes(selected).first {
                ($0.attachments[LayoutDebugAttachmentKey.debugName] as? String) == "rail-selection-tile"
            })
            let glyph = try #require(nodes(selected).first { $0.viewTag?.contains(".Image") == true })
            #expect(tile.frame.width == 40 && tile.frame.height == 40)
            #expect(abs(tile.absoluteFrame.midX - selected.absoluteFrame.midX) < 0.5)
            #expect(abs(tile.absoluteFrame.midY - selected.absoluteFrame.midY) < 0.5)
            #expect(abs(glyph.absoluteFrame.midX - tile.absoluteFrame.midX) < 0.5)
            #expect(abs(glyph.absoluteFrame.midY - tile.absoluteFrame.midY) < 0.5)
            #expect(tile.backgroundColor == theme.colors.surfaceVariant)
            #expect(glyph.inheritedForegroundColor == theme.colors.onSurface)
            #expect(!nodes(selected).contains {
                ($0.attachments[LayoutDebugAttachmentKey.debugName] as? String) == "rail-selection-indicator"
            })

            let hovered = try row(1, graph)
            let hoverGlyph = try #require(nodes(hovered).first { $0.viewTag?.contains(".Image") == true })
            #expect(hoverGlyph.inheritedForegroundColor == theme.colors.onSurfaceVariant)
            let bounds = hovered.absoluteFrame
            input.dispatch(.mouseMotion(MouseMotionEvent(x: Float(bounds.midX), y: Float(bounds.midY),
                                                         deltaX: 0, deltaY: 0)))
            settle(graph, harness)
            let hoverTile = try #require(nodes(try row(1, graph)).first {
                ($0.attachments[LayoutDebugAttachmentKey.debugName] as? String) == "rail-selection-tile"
            })
            let hoveredGlyph = try #require(
                nodes(try row(1, graph)).first { $0.viewTag?.contains(".Image") == true })
            #expect(hoverTile.backgroundColor == theme.colors.stateLayerHover)
            #expect(hoveredGlyph.inheritedForegroundColor == theme.colors.onSurface)
        }
    }

    @Test("Touch activates at the target edge; disabling or removing a pressed rail releases input")
    func pointerLifecycle() throws {
        try scene { harness, graph, context, input, _, _ in
            harness.input = [.touch]
            harness.selected = 0
            harness.presentation = .rail(showsLabels: false)
            settle(graph, harness)
            let row = try row(0, graph)
            let bounds = row.absoluteFrame
            let point = MouseButtonEvent(button: .left, x: Float(bounds.minX + 1), y: Float(bounds.maxY - 1), clicks: 1)
            input.dispatch(.mouseButtonDown(point))
            input.dispatch(.mouseButtonUp(point))
            settle(graph, harness)
            #expect(
                harness.activations == 1 && harness.selected == 0,
                "row \(bounds), capture \(context.pointerCapture.target?.accessibility?.label ?? "nil")")
            input.dispatch(.mouseButtonDown(point))
            #expect(context.pointerCapture.target?.id == row.id)
            harness.enabled = false
            settle(graph, harness)
            #expect(
                context.pointerCapture.target == nil && !row.isFocusable && row.accessibility?.state.isEnabled == false)
            input.dispatch(.mouseButtonUp(point))
            #expect(harness.activations == 1)
            harness.enabled = true
            settle(graph, harness)
            input.dispatch(.mouseButtonDown(point))
            graph.install(root: EmptyView())
            graph.recomposer.commitAll()
            #expect(context.pointerCapture.target == nil && context.focusChain.focused == nil)
        }
    }

    @Test("AI tools find full names in an icon-only rail without decorative duplicate controls")
    func iconDiscovery() async throws {
        let graph = GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(
                root: NavigationRail(
                    selection: .constant(0),
                    items: [
                        SidebarItem(0, "Workspace notifications") { $0.badge = "999" },
                        SidebarItem(1, "Unavailable") { $0.isEnabled = false },
                    ], showsLabels: false
                ).frame(height: 180))
            for _ in 0..<8 {
                graph.recomposer.commitAll()
                graph.computeLayout(width: 390, height: 180)
            }
            return graph
        }
        defer { GlobalTestLock.locked { graph.install(root: EmptyView()) } }
        let diagnostics = UIDiagnostics(tree: graph.tree)
        let toolbox = try diagnostics.toolbox()
        let result = try await toolbox.execute(
            name: "query_ui_nodes",
            input: Data(#"{"text":"Workspace notifications","role":"button","input_enabled_only":true}"#.utf8))
        let response = try #require(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
        let data = try #require(response["data"] as? [String: Any])
        #expect(data["total"] as? Int == 1)
        let found = try #require(diagnostics.queryNodes(text: "Workspace notifications", role: "button").items.first)
        #expect(found.semantics?.value == "999" && found.semantics?.state.isSelected == true)
        #expect(try diagnostics.queryNodes(text: "Unavailable", role: "button", inputEnabledOnly: true).total == 0)
    }
}
