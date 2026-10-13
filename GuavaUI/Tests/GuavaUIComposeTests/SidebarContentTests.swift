import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

private struct SidebarScene: View {
    var viewport: Float = 360
    @State var scale: Float = 1
    @State var selected: String? = "projects"
    @State var icons = true
    var body: some View {
        Sidebar(selection: $selected, sections: [
            SidebarSection("workspace", items: [
                SidebarItem("projects", "Projects") { $0.icon = icons ? UIIcons.File.folder : nil; $0.badge = "88" },
                SidebarItem("recent", "Recent activity"),
                SidebarItem("disabled", "Team permissions", configure: { $0.icon = icons ? UIIcons.Status.lock : nil; $0.isEnabled = false }),
                SidebarItem("settings", "Settings", configure: { $0.icon = icons ? UIIcons.Action.settings : nil; $0.iconSize = .init { _ in 19 } }),
                SidebarItem("long", "A destination with a long descriptive title", configure: { $0.icon = icons ? UIIcons.File.file : nil; $0.badge = "999" })
            ])
        ]).frame(width: 260, height: viewport).textScaler(.init(scale))
    }
}

private struct SidebarSlotScene: View {
    @State var scale: Float = 1
    var body: some View {
        Sidebar(selection: .constant("project"), sections: [
            SidebarSection("main", items: [SidebarItem("project", "Project")])
        ], header: {
            Row(alignment: .center, spacing: 10) {
                Icon(UIIcons.File.package, size: .large).flex(0, shrink: 0)
                Text("Guava workspace").font(.bodyStrong).flex(1, shrink: 1).frame(minWidth: 0)
            }.padding(16).debugName("sidebar-slot-header")
            Divider()
        }, footer: {
            Divider()
            Row(alignment: .center, spacing: 8) {
                Icon(UIIcons.Shape.circleDot, size: .small)
                Text("All changes saved").font(.caption)
            }.padding(14).debugName("sidebar-slot-footer")
        }).frame(width: 260, height: 420).textScaler(.init(scale))
    }
}

@Suite("Sidebar content and input", .serialized)
struct SidebarContentTests: GuavaUIComposeSerializedSuite {
    private func fixture(_ work: (ViewGraph, PlatformInputContext) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make(size: 14, lineHeight: 20)
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext()
            try context.withCurrent {
                try AnimatorScheduler.$current.withValue(AnimatorScheduler()) {
                    let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                    defer { graph.install(root: EmptyView()) }
                    try work(graph, context)
                }
            }
        }
    }
    private func all(_ node: Node) -> [Node] { [node] + node.children.flatMap(all) }
    private func named(_ name: String, _ graph: ViewGraph) throws -> Node {
        try #require(all(graph.tree.root!).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name })
    }
    private func settle(_ graph: ViewGraph, height: Float = 360) {
        for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 260, height: height) }
    }
    private func glyph(_ id: String, _ graph: ViewGraph) throws -> Node {
        try #require(all(try named("sidebar-item-\(id)", graph)).first { $0.viewTag?.contains(".Image") == true })
    }
    private func dispatcher(_ graph: ViewGraph, _ context: PlatformInputContext) -> EventDispatcher {
        EventDispatcher(tree: graph.tree, interactions: context.interactions, capture: context.pointerCapture, focusChain: context.focusChain)
    }

    @Test("Mixed icon roles reserve one lane; dynamic scaling grows glyphs, rows and badges without overlap")
    func scaledAlignment() throws {
        try fixture { graph, _ in
            let scene = SidebarScene()
            graph.install(root: scene.theme(.defaultLight)); settle(graph)
            let first = try glyph("projects", graph), last = try glyph("settings", graph)
            #expect(first.frame.width == 16 && last.frame.width == 19)
            // Yoga rounds to the pixel grid: an odd-width lane can differ by
            // half a logical point at 1x, while retaining its shared center.
            #expect(abs(first.absoluteFrame.midX - last.absoluteFrame.midX) <= 0.5, "Glyphs: \(first.absoluteFrame), \(last.absoluteFrame)")
            let before = try named("sidebar-item-projects", graph).frame.height
            scene.$scale.wrappedValue = 2; settle(graph)
            #expect(try glyph("projects", graph).frame.width == 32)
            #expect(try glyph("settings", graph).frame.width == 38)
            let title = try named("sidebar-title-projects", graph).absoluteFrame
            let recent = try named("sidebar-title-recent", graph).absoluteFrame
            let settings = try named("sidebar-title-settings", graph).absoluteFrame
            #expect(title.minX == recent.minX && title.minX == settings.minX)
            let row = try named("sidebar-item-projects", graph).absoluteFrame
            let badge = try named("sidebar-badge-projects", graph).absoluteFrame
            #expect(row.height > before && row.contains(title) && row.contains(badge), "Before \(before), row \(row), title \(title), badge \(badge)")
            #expect(title.maxX + 9 <= badge.minX && abs(title.midY - badge.midY) < 0.5)
            let longRow = try named("sidebar-item-long", graph).absoluteFrame
            let longTitle = try named("sidebar-title-long", graph).absoluteFrame
            let longBadge = try named("sidebar-badge-long", graph).absoluteFrame
            #expect(longTitle.height > 36 && longRow.contains(longTitle) && longRow.contains(longBadge), "Row \(longRow), title \(longTitle), badge \(longBadge)")
            #expect(longTitle.maxX + 9 <= longBadge.minX)
            scene.$icons.wrappedValue = false; settle(graph)
            #expect(!all(graph.tree.root!).contains { $0.viewTag?.contains(".Image") == true })
            #expect(try named("sidebar-title-projects", graph).absoluteFrame.minX < title.minX)
        }
    }

    @Test("Icon foreground and destination semantics survive hover/focus recomposition in both themes", arguments: [false, true])
    func semanticsAndColor(dark: Bool) throws {
        try fixture { graph, context in
            let theme = dark ? Theme.defaultDark : Theme.defaultLight
            graph.install(root: SidebarScene().theme(theme)); settle(graph)
            let row = try named("sidebar-item-projects", graph)
            #expect(row.accessibility?.label == "Projects" && row.accessibility?.value == "88")
            #expect(row.accessibility?.state.isSelected == true)
            #expect(try glyph("projects", graph).inheritedForegroundColor == theme.colors.onSurface)
            let disabled = try named("sidebar-item-disabled", graph)
            #expect(!disabled.isFocusable && disabled.accessibility?.state.isEnabled == false)
            #expect(try glyph("disabled", graph).inheritedForegroundColor == SemanticColorRef.onSurfaceDisabled.resolve(theme))
            context.focusChain.focus(row); settle(graph)
            #expect(row.accessibility?.label == "Projects" && row.accessibility?.value == "88")
            #expect(all(row).contains { $0.borderColor == theme.colors.focusRing && $0.borderWidth == 2 })
            let frame = row.absoluteFrame
            dispatcher(graph, context).dispatch(.mouseMotion(MouseMotionEvent(x: Float(frame.midX), y: Float(frame.midY), deltaX: 0, deltaY: 0)))
            settle(graph)
            #expect(row.accessibility?.state.isSelected == true && row.accessibility?.label == "Projects")
            // Selection comes from the shared appearance, so a hovered *selected*
            // destination layers the state layer over the same accent fill a list
            // row uses.
            let selection = SelectionAppearance.resolve(.navigation, theme: theme)
            #expect(all(row).contains { $0.backgroundColor == selection.hoverFill.composited(over: selection.fill) })
        }
    }

    @Test("Vertical keyboard selection skips disabled destinations, updates one tab stop and reveals offscreen rows")
    func keyboardScrollAndDisabledClick() throws {
        try fixture { graph, context in
            let scene = SidebarScene(viewport: 130)
            graph.install(root: scene.theme(.defaultLight)); settle(graph, height: 130)
            let input = dispatcher(graph, context)
            func key(_ code: UInt32, modifiers: KeyModifiers = []) {
                input.dispatch(.keyDown(KeyEvent(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)))
                settle(graph, height: 130)
            }
            context.focusChain.focus(try named("sidebar-item-recent", graph))
            key(Scancode.arrowDown)
            let settings = try named("sidebar-item-settings", graph)
            #expect(scene.selected == "settings" && context.focusChain.focused === settings)
            #expect(all(graph.tree.root!).filter { $0.attachments["__roving.item"] != nil && $0.isTabStop }.count == 1)
            key(Scancode.end)
            let target = try named("sidebar-item-long", graph)
            let scroll = try #require(all(graph.tree.root!).first { $0.attachments[ScrollReveal.handlerKey] != nil })
            #expect(scene.selected == "long" && scroll.contentOffset.y > 0, "Selection \(String(describing: scene.selected)), offset \(scroll.contentOffset)")
            #expect(target.absoluteFrame.maxY <= scroll.absoluteFrame.maxY + 0.5, "Target \(target.absoluteFrame), viewport \(scroll.absoluteFrame)")
            key(Scancode.home)
            #expect(scene.selected == "projects" && scroll.contentOffset.y <= 10, "Offset \(scroll.contentOffset)")
            key(Scancode.arrowRight); key(Scancode.arrowDown, modifiers: [.lshift])
            #expect(scene.selected == "projects")
            let disabled = try named("sidebar-item-disabled", graph).absoluteFrame
            let click = MouseButtonEvent(button: .left, x: Float(disabled.midX), y: Float(disabled.midY), clicks: 1)
            input.dispatch(.mouseButtonDown(click)); input.dispatch(.mouseButtonUp(click)); settle(graph, height: 130)
            #expect(scene.selected == "projects")
        }
    }

    @Test("Multiple header/footer views retain separate layout boundaries during dynamic scale changes")
    func slotGeometry() throws {
        try fixture { graph, _ in
            let scene = SidebarSlotScene()
            graph.install(root: scene.theme(.defaultLight)); settle(graph, height: 420)
            let before = try named("sidebar-slot-header", graph).frame.height
            scene.$scale.wrappedValue = 2; settle(graph, height: 420)
            let header = try named("sidebar-slot-header", graph), footer = try named("sidebar-slot-footer", graph)
            let scroll = try #require(all(graph.tree.root!).first { $0.attachments[ScrollReveal.handlerKey] != nil })
            #expect(header.frame.height > before)
            #expect(scroll.absoluteFrame.minY >= header.absoluteFrame.maxY)
            #expect(scroll.absoluteFrame.maxY <= footer.absoluteFrame.minY)
            for slot in [header, footer] {
                for child in all(slot).filter({ $0.layoutNode?.textInputs != nil || $0.viewTag?.contains(".Image") == true }) {
                    #expect(slot.absoluteFrame.contains(child.absoluteFrame))
                }
            }
            let icon = try #require(all(header).first { $0.viewTag?.contains(".Image") == true })
            #expect(icon.frame.width == 48 && icon.frame.height == 48)
        }
    }

    @Test("Initial and externally changed selection reveal once without trapping subsequent user scrolling")
    func controlledSelectionReveal() throws {
        try fixture { graph, _ in
            let scene = SidebarScene(viewport: 130)
            graph.install(root: scene.theme(.defaultLight)); settle(graph, height: 130)
            scene.$selected.wrappedValue = "settings"; settle(graph, height: 130)
            let scroll = try #require(all(graph.tree.root!).first { $0.attachments[ScrollReveal.handlerKey] != nil })
            #expect(scroll.contentOffset.y > 0)
            #expect(try named("sidebar-item-settings", graph).absoluteFrame.maxY <= scroll.absoluteFrame.maxY)
            // An explicit user scroll must remain available after the reveal.
            scroll.contentOffset = .zero; settle(graph, height: 130)
            #expect(scroll.contentOffset == .zero)
            graph.install(root: EmptyView())
            graph.install(root: Sidebar(selection: .constant("last"), sections: [
                SidebarSection("many", items: (0..<10).map { SidebarItem("\($0)", "Destination \($0)") } + [SidebarItem("last", "Last")])
            ]).frame(width: 260, height: 130).theme(.defaultLight))
            settle(graph, height: 130)
            let initial = try #require(all(graph.tree.root!).first { $0.attachments[ScrollReveal.handlerKey] != nil })
            #expect(initial.contentOffset.y > 0)
            #expect(try named("sidebar-item-last", graph).absoluteFrame.maxY <= initial.absoluteFrame.maxY)
        }
    }
}
