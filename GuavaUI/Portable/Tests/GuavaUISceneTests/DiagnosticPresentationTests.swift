import Foundation
import Testing
import GuavaUIScene
import GuavaUIDevToolsScene
import GuavaUIAgentCore

@Suite("AI control presentation", .serialized)
@MainActor
struct DiagnosticPresentationTests {
    private func button(_ text: String, frame: CGRect) -> Node {
        let button = Node()
        button.frame = frame
        button.isFocusable = true
        button.accessibility = AccessibilitySemantics(.button) { $0.combinesChildren = true }
        let label = Node()
        label.frame = CGRect(x: 2, y: 2, width: 50, height: 20)
        label.accessibility = AccessibilitySemantics(.staticText) { $0.label = text }
        button.addChild(label)
        return button
    }

    @Test("The AI tool finds an ordinary composite button by the same label as native accessibility")
    func composedName() async throws {
        let root = Node(), tree = NodeTree()
        root.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let control = button("Open workspace", frame: CGRect(x: 10, y: 20, width: 120, height: 40))
        let hidden = Node()
        hidden.opacity = 0
        hidden.accessibility = AccessibilitySemantics(.staticText) { $0.label = "Do not announce" }
        control.addChild(hidden)
        var reads = 0
        control.accessibilityValueProvider = AccessibilityValueProvider(revision: 1) { reads += 1; return "private" }
        root.addChild(control); tree.root = root
        let diagnostics = UIDiagnostics(tree: tree), toolbox = try diagnostics.toolbox()
        let result = try await toolbox.execute(name: "query_ui_nodes",
            input: Data(#"{"text":"Open workspace","role":"button","visible_only":true}"#.utf8))
        let response = try #require(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
        let data = try #require(response["data"] as? [String: Any])
        #expect(data["total"] as? Int == 1 && reads == 0)
        let node = try #require(diagnostics.queryNodes(text: "Open workspace", role: "button", visibleOnly: true).items.first)
        #expect(node.node.id == String(control.id.rawValue))
        #expect(node.semantics?.label == "Open workspace" && node.presentation.inputEnabled)
        let native = AccessibilityTree.snapshot(root: root, resolveValues: false).flatMap(flatten)
        #expect(native.first { $0.node.id == control.id }?.semantics.label == node.semantics?.label)
        #expect(reads == 0)
    }

    @Test("Clipped visible bounds include scroll offsets; input availability inherits disabled ancestors")
    func clippingAndInput() throws {
        let root = Node(), clip = Node(), tree = NodeTree()
        root.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        clip.frame = CGRect(x: 50, y: 40, width: 80, height: 60)
        clip.clipsToBounds = true; clip.contentOffset = CGPoint(x: 10, y: 5)
        let control = button("Run", frame: CGRect(x: 60, y: 20, width: 100, height: 60))
        clip.addChild(control); root.addChild(clip); tree.root = root
        let diagnostics = UIDiagnostics(tree: tree)
        let result = try #require(diagnostics.queryNodes(text: "Run", role: "button", visibleOnly: true).items.first)
        let frame = try #require(result.presentation.visibleFrame)
        #expect(frame.x == 100 && frame.y == 55 && frame.w == 30 && frame.h == 45)
        #expect(result.presentation.isVisible && result.presentation.inputEnabled)
        clip.allowsHitTesting = false
        let disabled = try #require(diagnostics.queryNodes(text: "Run", role: "button", visibleOnly: true).items.first)
        #expect(disabled.presentation.isVisible && !disabled.presentation.inputEnabled)
        clip.opacity = 0
        #expect(try diagnostics.queryNodes(text: "Run", role: "button", visibleOnly: true).total == 0)
        let hidden = try #require(diagnostics.queryNodes(id: String(control.id.rawValue)).items.first)
        #expect(!hidden.presentation.isVisible && hidden.presentation.visibleFrame == nil)
    }

    @Test("Offscreen/retained branches are inspectable without being suggested as visible controls")
    func retainedBranches() throws {
        let root = Node(), retained = Node(), tree = NodeTree()
        root.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        retained.opacity = 0; retained.isInteractionEnabled = false
        retained.addChild(button("Share", frame: CGRect(x: 10, y: 20, width: 80, height: 30)))
        root.addChild(retained)
        root.addChild(button("Share", frame: CGRect(x: 10, y: 80, width: 80, height: 30)))
        root.addChild(button("Share", frame: CGRect(x: 500, y: 80, width: 80, height: 30)))
        tree.root = root
        let diagnostics = UIDiagnostics(tree: tree)
        #expect(try diagnostics.queryNodes(text: "Share", role: "button").total == 3)
        let visible = try diagnostics.queryNodes(text: "Share", role: "button", visibleOnly: true, limit: 1)
        #expect(visible.total == 1 && visible.items.count == 1 && visible.nextOffset == nil)
    }

    private func flatten(_ element: AccessibilityElement) -> [AccessibilityElement] {
        [element] + element.children.flatMap(flatten)
    }
}
