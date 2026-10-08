import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Control motion", .serialized)
struct ControlMotionTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    @Test("Field hover interpolates the border and preserves its value")
    func fieldHover() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext()
        let scheduler = AnimatorScheduler()
        try context.withCurrent {
            try AnimatorScheduler.$current.withValue(scheduler) {
                var theme = Theme.defaultDark
                theme.motion.fast = .milliseconds(200)
                theme.inputs.borderHover = .white
                var value: TextBuffer = "12.5"
                let tree = NodeTree()
                let graph = ViewGraph(tree: tree, recomposer: Recomposer())
                graph.install(root: TextField(text: Binding(get: { value }, set: { value = $0 })).theme(theme))
                graph.computeLayout(width: 120, height: 28)
                let field = try #require(nodes(tree.root).first { $0.attachments["__textfield_chrome_hover"] != nil })
                let hover = try #require(context.interactions.handlers(for: field).hover)
                hover(.enter); graph.recomposer.commitAll()
                #expect(field.borderColor == theme.inputs.borderColor)
                scheduler.tick(deltaTime: 0.1)
                #expect(field.borderColor != theme.inputs.borderColor)
                #expect(field.borderColor != theme.inputs.borderHover)
                scheduler.tick(deltaTime: 1)
                #expect(field.borderColor == theme.inputs.borderHover)
                hover(.leave); graph.recomposer.commitAll(); scheduler.tick(deltaTime: 1)
                #expect(field.borderColor == theme.inputs.borderColor)
                #expect(value.stringValue == "12.5")
            }
        }
    } }

    private struct SwitchHarness: View {
        @State var enabled = false
        var body: some View { Toggle(isOn: $enabled) }
    }

    @Test("Switch value changes immediately while the thumb travels smoothly")
    func switchMotion() throws { try GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        try AnimatorScheduler.$current.withValue(scheduler) {
            let harness = SwitchHarness()
            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root: harness)
            graph.computeLayout(width: 100, height: 40)
            let toggle = try #require(nodes(tree.root).first { $0.attachments[BoolControlHost.onKey] != nil })
            harness.$enabled.wrappedValue = true; graph.recomposer.commitAll()
            #expect(toggle.attachments[BoolControlHost.onKey] as? Bool == true)
            #expect(toggle.attachments["__bool_visual_progress"] as? Float == 0)
            scheduler.tick(deltaTime: 0.04)
            let midpoint = try #require(toggle.attachments["__bool_visual_progress"] as? Float)
            #expect(midpoint > 0 && midpoint < 1)
            harness.$enabled.wrappedValue = false; graph.recomposer.commitAll()
            #expect(toggle.attachments["__bool_visual_progress"] as? Float == midpoint)
            scheduler.tick(deltaTime: 1)
            #expect(toggle.attachments["__bool_visual_progress"] as? Float == 0)
            #expect(scheduler.activeCount == 0)
        }
    } }
}
