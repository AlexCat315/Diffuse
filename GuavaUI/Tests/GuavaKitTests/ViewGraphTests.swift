import Testing
@testable import GuavaKit

@Suite("GuavaKit viewgraph")
struct ViewGraphTests {

    /// Lets a test trigger a state mutation that the view set up in its body.
    private final class ActionBox { var fire: () -> Void = {} }

    // MARK: - Structure

    private struct App: View {
        var body: some View {
            Stack(.column) {
                Element(width: 10, height: 10)
                Element(width: 20, height: 20)
            }
        }
    }

    @Test("A declarative tree materializes into the right node tree")
    func materialize() {
        let ctx = UIContext()
        let graph = ViewGraph(context: ctx)
        graph.install(root: App())
        // root → Stack → [Element, Element]
        #expect(graph.root.children.count == 1)
        let stack = graph.root.children[0]
        #expect(stack.children.count == 2)
        #expect(stack.children[0].layoutStyle.width == .points(10))
        #expect(stack.children[1].layoutStyle.width == .points(20))
    }

    // MARK: - @State survives recompose, node identity preserved

    private struct Counter: View {
        @State var count: Int = 0
        let actions: ViewGraphTests.ActionBox
        var body: some View {
            actions.fire = { count += 1 }
            return Element(width: Float(count * 10), height: 10)
        }
    }

    @Test("@State survives recompose; the same node is reused and updated")
    func stateSurvives() {
        let ctx = UIContext()
        let graph = ViewGraph(context: ctx)
        let actions = ActionBox()
        graph.install(root: Counter(actions: actions))

        let node = graph.root.children[0]
        #expect(node.layoutStyle.width == .points(0))

        actions.fire()                      // count → 1, scope marked dirty
        #expect(graph.recomposer.hasPending)
        graph.commitIfNeeded()

        // Same node object (identity preserved via path), with the new value.
        #expect(graph.root.children[0] === node)
        #expect(node.layoutStyle.width == .points(10))
    }

    @Test("commitIfNeeded is a no-op without a state change")
    func gatedCommit() {
        let ctx = UIContext()
        let graph = ViewGraph(context: ctx)
        let actions = ActionBox()
        graph.install(root: Counter(actions: actions))
        #expect(graph.commitIfNeeded() == false)
        actions.fire()
        #expect(graph.commitIfNeeded() == true)
        #expect(graph.commitIfNeeded() == false)
    }

    // MARK: - Conditional content adds/removes nodes (and tears them down)

    private struct Toggler: View {
        @State var show: Bool = true
        let actions: ViewGraphTests.ActionBox
        var body: some View {
            actions.fire = { show.toggle() }
            return Stack(.column) {
                Element(width: 10, height: 10)
                if show {
                    Element(width: 20, height: 20, color: Color(r: 0, g: 0, b: 1))
                }
            }
        }
    }

    @Test("Conditional view toggles a child node in and out, detaching on remove")
    func conditionalAddRemove() {
        let ctx = UIContext()
        let graph = ViewGraph(context: ctx)
        let actions = ActionBox()
        graph.install(root: Toggler(actions: actions))

        let stack = graph.root.children[0]
        #expect(stack.children.count == 2)
        let removed = stack.children[1]

        actions.fire()              // show = false
        graph.commitIfNeeded()
        #expect(stack.children.count == 1)
        #expect(removed.parent == nil)   // detached from the tree
        #expect(removed.context == nil)  // and released from the context

        actions.fire()              // show = true again
        graph.commitIfNeeded()
        #expect(stack.children.count == 2)
    }

    // MARK: - Nested user views each keep their own state

    private struct Outer: View {
        let a: ViewGraphTests.ActionBox
        let b: ViewGraphTests.ActionBox
        var body: some View {
            Stack(.row) {
                Counter(actions: a)
                Counter(actions: b)
            }
        }
    }

    @Test("Sibling user views hold independent state")
    func independentScopes() {
        let ctx = UIContext()
        let graph = ViewGraph(context: ctx)
        let a = ActionBox(); let b = ActionBox()
        graph.install(root: Outer(a: a, b: b))

        let stack = graph.root.children[0]
        #expect(stack.children.count == 2)

        a.fire(); a.fire()   // first counter → 2
        b.fire()             // second counter → 1
        graph.commitIfNeeded()

        #expect(stack.children[0].layoutStyle.width == .points(20))
        #expect(stack.children[1].layoutStyle.width == .points(10))
    }
}
