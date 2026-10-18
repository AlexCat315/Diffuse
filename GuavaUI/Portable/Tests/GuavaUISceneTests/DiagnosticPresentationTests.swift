import Foundation
import Testing
import GuavaUIScene
import GuavaUIDevToolsScene
import GuavaUIAgentCore
import GuavaUIDevToolsProtocol

@Suite("AI control presentation", .serialized)
@MainActor
struct DiagnosticPresentationTests {
    @Test("Explicit single-node reads resolve live values, bound Unicode output and never read secure providers")
    func explicitValues() async throws {
        let tree = NodeTree(), root = Node(), field = Node(), secure = Node()
        tree.root = root; root.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        root.addChild(field); root.addChild(secure)
        field.accessibility = AccessibilitySemantics(.textField) { $0.label = "Amount" }
        secure.accessibility = AccessibilitySemantics(.textField) { $0.state.isSecure = true }
        var value = "12,75", reads = 0, secureReads = 0
        field.accessibilityValueProvider = AccessibilityValueProvider(revision: 1) { reads += 1; return value }
        secure.accessibilityValueProvider = AccessibilityValueProvider(revision: 1) { secureReads += 1; return "secret" }
        let diagnostics = UIDiagnostics(tree: tree), toolbox = try diagnostics.toolbox()
        let id = String(field.id.rawValue)
        #expect(try diagnostics.queryNodes(id: id).items.first?.valueTruncated == nil)
        _ = diagnostics.queryRecomposition()
        #expect(reads == 0 && secureReads == 0)
        #expect(throws: AgentError.self) { try diagnostics.queryNodes(includeValue: true) }
        let first = try #require(diagnostics.queryNodes(id: id, includeValue: true).items.first)
        #expect(first.semantics?.value == "12,75" && first.valueTruncated == false && reads == 1)
        value = String(repeating: "🪴", count: 4097)
        let bounded = try #require(diagnostics.queryNodes(id: id, includeValue: true).items.first)
        #expect(bounded.semantics?.value.count == 4096 && bounded.valueTruncated == true)
        #expect(bounded.semantics?.value.last == "🪴")
        let secureID = String(secure.id.rawValue)
        let protected = try #require(diagnostics.queryNodes(id: secureID, includeValue: true).items.first)
        #expect(protected.semantics?.value == "<redacted>" && protected.valueTruncated == false)
        #expect(secureReads == 0)
        let arguments: JSONValue = .object(["node_id": .string(id), "include_value": .bool(true)])
        let wire = diagnostics.handleReadRequest(.init(type: "diagnostics.call", payload: .object([
            "name": .string("query_ui_nodes"), "arguments": arguments
        ])))
        let sdk = try await toolbox.execute(name: "query_ui_nodes", input: JSONEncoder().encode(arguments))
        let wireData = try JSONEncoder().encode(wire.payload)
        #expect(try JSONSerialization.jsonObject(with: wireData) as? NSDictionary
            == JSONSerialization.jsonObject(with: sdk.json) as? NSDictionary)
        root.removeChild(field)
        #expect(throws: AgentError.self) { try diagnostics.queryNodes(id: id, includeValue: true) }
        #expect(secureReads == 0)
    }

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

    @Test("Native Inspector snapshots expose accessibility roles while preserving an explicit diagnostic role")
    func inspectorRoles() {
        let root = button("Open", frame: CGRect(x: 0, y: 0, width: 100, height: 44)), tree = NodeTree()
        tree.root = root
        let inspector = SceneInspector(tree: tree)
        #expect(inspector.snapshot().root?.semanticRole == "button")
        root.attachments["GuavaUI.semantic.role"] = "navigationItem"
        #expect(inspector.snapshot().root?.semanticRole == "navigationItem")
    }

    private func flatten(_ element: AccessibilityElement) -> [AccessibilityElement] {
        [element] + element.children.flatMap(flatten)
    }

    @Test("AI input filtering follows nested modal scopes and accessory ownership without blocking another scene")
    func modalInputFiltering() async throws {
        let root = Node(), tree = NodeTree(), chain = FocusChain()
        root.frame = CGRect(x: 0, y: 0, width: 390, height: 640); tree.root = root
        let background = button("Background", frame: CGRect(x: 0, y: 0, width: 100, height: 44))
        let modal = Node(), resource = ModalFocusResource()
        modal.frame = root.frame
        modal.addResource(resource)
        let inside = button("Choose", frame: CGRect(x: 20, y: 100, width: 100, height: 44))
        modal.addChild(inside); root.addChild(background)
        var container = root
        for _ in 0..<64 {
            let anchor = Node(); container.addChild(anchor); container = anchor
        }
        container.addChild(modal)
        resource.bind(modal, chain: chain)
        defer { resource.unmount(node: modal) }
        let accessory = button("Submenu", frame: CGRect(x: 200, y: 100, width: 100, height: 44))
        root.addChild(accessory); chain.attachAccessory(accessory, owner: inside)
        defer { chain.detachAccessory(accessory) }
        let diagnostics = UIDiagnostics(tree: tree), toolbox = try diagnostics.toolbox()
        let blocked = try #require(diagnostics.queryNodes(text: "Background", role: "button").items.first)
        #expect(blocked.presentation.isVisible && !blocked.presentation.inputEnabled)
        #expect(try diagnostics.queryNodes(text: "Choose", role: "button", inputEnabledOnly: true).total == 1)
        #expect(try diagnostics.queryNodes(text: "Submenu", role: "button", inputEnabledOnly: true).total == 1)
        let result = try await toolbox.execute(name: "query_ui_nodes",
            input: Data(#"{"role":"button","input_enabled_only":true}"#.utf8))
        let response = try #require(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
        let data = try #require(response["data"] as? [String: Any])
        #expect(data["total"] as? Int == 2)
        let otherTree = NodeTree(), otherRoot = Node()
        otherRoot.frame = root.frame; otherTree.root = otherRoot
        otherRoot.addChild(button("Other window", frame: CGRect(x: 0, y: 0, width: 100, height: 44)))
        #expect(try UIDiagnostics(tree: otherTree).queryNodes(role: "button", inputEnabledOnly: true).total == 1)
        let nested = Node(), nestedResource = ModalFocusResource()
        nested.frame = root.frame; nested.addResource(nestedResource)
        nested.addChild(button("Nested", frame: CGRect(x: 20, y: 200, width: 100, height: 44)))
        root.addChild(nested); nestedResource.bind(nested, chain: chain)
        #expect(try diagnostics.queryNodes(role: "button", inputEnabledOnly: true).total == 1)
        nestedResource.unmount(node: nested); root.removeChild(nested)
        #expect(try diagnostics.queryNodes(role: "button", inputEnabledOnly: true).total == 2)
        resource.unmount(node: modal)
        #expect(try diagnostics.queryNodes(role: "button", inputEnabledOnly: true).total == 3)
    }
}
