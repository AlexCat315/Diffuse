import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Touch control extent and hover", .serialized)
struct TouchDensityTests: GuavaUIComposeSerializedSuite {
    private struct Harness<Content: View>: View {
        @State var input: UIEnvironment.Input = [.touch]
        let content: Content
        var body: some View {
            var surface = UIEnvironment(); surface.input = input
            return content.surfaceEnvironment(surface)
        }
    }
    private final class HoverRecorder { var values: [Bool] = [] }
    private struct HoverStyle: ButtonStyle {
        let recorder: HoverRecorder
        func makeBody(configuration: ButtonStyleConfiguration) -> some View {
            recorder.values.append(configuration.isHovered)
            return AnyView(configuration.label)
        }
    }
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }
    private func withScene(_ body: (ViewGraph, InteractionRegistry) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let oldText = TextEnvironmentHolder.current, oldRegistry = InteractionRegistryHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            let registry = InteractionRegistry(); InteractionRegistryHolder.current = registry
            defer { TextEnvironmentHolder.current = oldText; InteractionRegistryHolder.current = oldRegistry }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            try body(graph, registry)
            graph.install(root: EmptyView())
        }
    }
    private func environment(_ input: UIEnvironment.Input) -> UIEnvironment {
        var surface = UIEnvironment(); surface.input = input; return surface
    }
    private func controls() -> some View {
        Box(direction: .column, alignItems: .flexStart, spacing: 8) {
            Button("Action") {}.debugName("button")
            TextField("Name", text: Binding<TextBuffer>.constant(.empty)).debugName("field")
            Slider(value: .constant(0.5)).frame(width: 200).debugName("slider")
            Toggle(isOn: .constant(false)).debugName("toggle")
            Checkbox(isOn: .constant(false)).debugName("checkbox")
            Rating(value: .constant(2)).debugName("rating")
            NumberField(value: .constant(1), showsStepper: true).debugName("number")
            Stepper([StepperItem(0, "First"), StepperItem(1, "Second")], selection: .constant(0))
            Button("Segment") {}.buttonStyle(SegmentButtonStyle()).debugName("segment")
            List(0..<8, id: \.self, rowHeight: 30) { item, _ in Text("Row \(item)") }
                .frame(width: 240, height: 100).debugName("list")
            CalendarView(selection: .constant(nil)).debugName("calendar")
            TabView(selection: .constant(0), tabs: [TabItem("Overview", id: 0, configure: { $0.onClose = {} }) { Box {}.frame(height: 40) }, TabItem("Details", id: 1) { EmptyView() }]) {
                $0.variant = .segmented; $0.overflow = .scroll
            }.frame(width: 320, height: 130).debugName("tabs")
        }
    }

    @Test("all interactive control families reach 44 points, including virtual rows and rating lanes")
    func touchFamilies() throws { try withScene { graph, _ in
        graph.install(root: controls().surfaceEnvironment(environment([.touch])))
        for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 900, height: 2200) }
        let all = nodes(graph.tree.root!)
        let hosts = all.filter { $0.isHitTestable && $0.acceptsSubtreeInput && ($0.attachments[ButtonHost.markerKey] as? Bool == true
            || $0.accessibility?.role == .slider || $0.accessibility?.role == .toggle
            || $0.accessibility?.role == .checkbox || $0.accessibility?.role == .textField
            || $0.accessibility?.role == .listItem) }
        #expect(hosts.count > 50)
        for host in hosts {
            #expect(host.frame.width >= 44 && host.frame.height >= 44, "\(host.accessibility?.role.rawValue ?? "control"): \(host.frame)")
        }
        let rating = try #require(all.first { $0.attachments["rating.session"] != nil })
        let geometry = try #require((rating.attachments["rating.session"] as? RatingSession)?.configuration?.geometry)
        #expect(geometry.cellWidth == 44 && geometry.starSize == 20)
        let rows = all.filter { $0.accessibility?.role == .listItem && $0.attachments[_ListRowHost.hoveredKey] != nil }
        #expect(rows.count >= 2 && rows.allSatisfy { $0.frame.height == 44 })
        for pair in zip(rows, rows.dropFirst()) { #expect(pair.1.absoluteFrame.minY - pair.0.absoluteFrame.minY == 44) }
        let tabs = try #require(all.first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "tabs" })
        for button in nodes(tabs).filter({ $0.attachments[ButtonHost.markerKey] as? Bool == true }) {
            #expect(button.absoluteFrame.minY >= tabs.absoluteFrame.minY && button.absoluteFrame.maxY <= tabs.absoluteFrame.maxY)
            var parent = button.parent
            while let ancestor = parent {
                if ancestor.clipsToBounds {
                    #expect(button.absoluteFrame.minY >= ancestor.absoluteFrame.minY && button.absoluteFrame.maxY <= ancestor.absoluteFrame.maxY)
                    break
                }
                parent = ancestor.parent
            }
        }
    } }

    @Test("switching input restores authored constraints and desktop density on retained nodes")
    func densityRestoration() throws { try withScene { graph, _ in
        func content() -> some View {
            Box(direction: .column, alignItems: .flexStart, spacing: 8) {
                Button("Action") {}.frame(minHeight: 38).debugName("authored")
                Toggle(isOn: .constant(false)).debugName("switch")
                Slider(value: .constant(0)).frame(width: 200).debugName("slider")
                TextField("Name", text: Binding<TextBuffer>.constant(.empty)).controlSize(.small).debugName("field")
            }
        }
        let harness = Harness(content: content())
        graph.install(root: harness); graph.computeLayout(width: 400, height: 400)
        let authored = try #require(nodes(graph.tree.root!).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "authored" })
        #expect(authored.frame.height == 44 && authored.layoutNode?.minHeight == 38)
        harness.input = [.pointer, .keyboard]
        graph.recomposer.commitAll(); graph.computeLayout(width: 400, height: 400)
        let restored = try #require(nodes(graph.tree.root!).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "authored" })
        #expect(restored === authored && restored.frame.height == 38 && restored.layoutNode?.minHeight == 38)
        for (name, height): (String, CGFloat) in [("switch", 24), ("slider", 24), ("field", 28)] {
            let node = try #require(nodes(graph.tree.root!).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name })
            #expect(node.frame.height == height)
        }
    } }

    @Test("touch-only surfaces ignore hover while hybrid surfaces retain pointer hover")
    func modalityHover() throws { try withScene { graph, registry in
        let harness = Harness(content: controls())
        graph.install(root: harness)
        for (input, expected): (UIEnvironment.Input, Bool) in [([.pointer], true), ([.touch], false), ([.touch, .pointer], true)] {
            harness.input = input
            graph.recomposer.commitAll()
            graph.computeLayout(width: 900, height: 2200)
            for (key, role): (String, AccessibilityRole) in [(ButtonHost.hoveredKey, .button), (BoolControlHost.hoveredKey, .toggle), (SliderHost.hoveredKey, .slider), (_ListRowHost.hoveredKey, .listItem)] {
                let node = try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == role && registry.handlers(for: $0).hover != nil && $0.attachments[key] != nil })
                registry.handlers(for: node).hover?(.enter)
                #expect(node.attachments[key] as? Bool == expected)
            }
            graph.recomposer.commitAll()
        }
    } }
    @Test("custom button styles clear hover state on a pointer-to-touch transition")
    func customStyleHover() throws { try withScene { graph, registry in
        let recorder = HoverRecorder()
        let harness = Harness(content: Button("Custom") {}.buttonStyle(HoverStyle(recorder: recorder)))
        harness.input = [.pointer]; graph.install(root: harness)
        graph.computeLayout(width: 300, height: 100)
        let button = try #require(nodes(graph.tree.root!).first { $0.attachments[ButtonHost.markerKey] as? Bool == true })
        registry.handlers(for: button).hover?(.enter); graph.recomposer.commitAll()
        #expect(recorder.values.last == true)
        harness.input = [.touch]; graph.recomposer.commitAll(); graph.computeLayout(width: 300, height: 100)
        graph.recomposer.commitAll()
        #expect(recorder.values.last == false && !graph.recomposer.hasPending)
        registry.handlers(for: button).hover?(.enter); graph.recomposer.commitAll()
        #expect(recorder.values.last == false && !graph.recomposer.hasPending)
    } }

    @Test("text hover queries clear once when pointer input disappears and do not run on touch motion")
    func textHoverQueryGating() throws { try withScene { graph, registry in
        var anchors: [TextFieldHoverAnchor?] = []
        let harness = Harness(content: TextField("Name", text: .constant("Hello")) {
            $0.events.onHoverChange = { anchors.append($0) }
        })
        harness.input = [.pointer]; graph.install(root: harness)
        graph.computeLayout(width: 300, height: 100)
        let field = try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == .textField })
        let motion = MouseMotionEvent(x: Float(field.absoluteFrame.minX + 10), y: Float(field.absoluteFrame.midY), deltaX: 0, deltaY: 0)
        _ = registry.handlers(for: field).motion?(motion, .target)
        #expect(anchors.count == 1 && anchors[0] != nil)
        harness.input = [.touch]; graph.recomposer.commitAll(); graph.computeLayout(width: 300, height: 100)
        #expect(anchors.count == 2 && anchors[1] == nil)
        for _ in 0..<3 {
            _ = registry.handlers(for: field).motion?(motion, .target)
            graph.recomposer.commitAll(); graph.computeLayout(width: 300, height: 100)
        }
        #expect(anchors.count == 2 && !graph.recomposer.hasPending)
    } }

}
