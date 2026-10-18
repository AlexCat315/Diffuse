import Foundation
import Testing
import GuavaUIRuntime
import GuavaUIAgent
import GuavaUIDevToolsProtocol
@testable import GuavaUICompose

@Suite("Nested sidebar navigation", .serialized)
@MainActor
struct SidebarHierarchyTests: GuavaUIComposeSerializedSuite {
  private struct Document: View {
    @State private var draft: TextBuffer = "Retained document"
    var body: some View {
      Column {
        TextField("Draft", text: $draft).debugName("hierarchy-draft")
        ScrollView(.vertical) { Text("Document content").frame(height: 1200) }
          .flex(1, shrink: 1, basis: 0).debugName("hierarchy-scroll")
      }.debugName("hierarchy-document")
    }
  }
  private final class Harness: View {
    let adaptive: Bool
    @State var selection: String? = "overview"
    @State var expanded: Set<String> = []
    @State var open = false
    @State var controlled = true
    @State var rail = false
    @State var disabled = false
    @State var removed = false
    @State var moved = false
    @State var activations = 0
    @State var archived = 0
    @State var width: Float = 1280
    @State var scale: Float = 1
    @State var dark = false
    @State var rtl = false
    @State var input: UIEnvironment.Input = [.pointer, .keyboard]
    init(adaptive: Bool) { self.adaptive = adaptive }
    var sections: [SidebarSection<String>] {
      let audit = SidebarItem("audit", "Audit trail") {
        $0.badge = "12"
        $0.contextMenu = [.item(MenuItem(id: "archive", title: "Archive") { self.archived += 1 })]
      }
      let team = SidebarItem("team", "Team") {
        $0.children = (removed || moved ? [] : [audit]) + [SidebarItem("billing", "Billing") { $0.isEnabled = false }]
      }
      let projects = SidebarItem("projects", "Projects") {
        $0.icon = UIIcons.File.folder; $0.isEnabled = !disabled
        $0.children = [SidebarItem("welcome", "Welcome"), team,
                      SidebarItem("locked", "Locked group") {
                        $0.isEnabled = false; $0.children = [SidebarItem("secret", "Secret")]
                      }] + (moved ? [audit] : [])
      }
      return [SidebarSection("workspace", title: "Workspace", items: [SidebarItem("overview", "Overview"), projects,
                                                                        SidebarItem("settings", "Settings")])]
    }
    var body: some View {
      var surface = UIEnvironment(); surface.viewport.width = width; surface.viewport.height = 360; surface.input = input
      return LayerRoot {
        if adaptive {
          AdaptiveSidebar("Workspace", isPresented: $open, selection: $selection,
                          expanded: controlled ? $expanded : nil, sections: sections,
                          configure: { $0.layout.showsRailLabels = false }) { Document() }
        } else {
          Sidebar(selection: $selection, sections: sections, presentation: rail ? .rail(showsLabels: false) : .expanded,
                  expanded: controlled ? $expanded : nil, onActivate: { _ in self.activations += 1 })
            .frame(width: rail ? 56 : 280, height: 360)
        }
      }.frame(width: width, height: 360).surfaceEnvironment(surface).textScaler(.init(scale))
        .appearance(dark ? .dark : .light).layoutDirection(rtl ? .rtl : .ltr).reducedMotion()
    }
  }
  private func nodes(_ root: Node?) -> [Node] {
    var pending = root.map { [$0] } ?? [], result: [Node] = []
    while let node = pending.popLast() { result.append(node); pending.append(contentsOf: node.children.reversed()) }
    return result
  }
  private func named(_ name: String, _ graph: ViewGraph) throws -> Node {
    try #require(nodes(graph.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name })
  }
  private func item(_ id: String, _ graph: ViewGraph) throws -> Node {
    let marker = try named("sidebar-item-\(id)", graph)
    return nodes(marker).first { $0.attachments[ButtonHost.markerKey] != nil } ?? marker
  }
  private func settle(_ graph: ViewGraph, _ h: Harness) {
    for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: h.width, height: 360); AnimatorScheduler.current.tick(deltaTime: 1) }
  }
  private func scene(adaptive: Bool = false, _ work: (Harness, ViewGraph, PlatformInputContext, EventDispatcher) throws -> Void) rethrows {
    try GlobalTestLock.locked {
      let previous = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
      defer { TextEnvironmentHolder.current = previous }
      let context = PlatformInputContext(); context.addScopedAmbient(PortalStoreAmbient(PortalStore()))
      try context.withCurrent {
        let h = Harness(adaptive: adaptive), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: h); settle(graph, h)
        defer { graph.install(root: EmptyView()) }
        try work(h, graph, context, EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                                   capture: context.pointerCapture, focusChain: context.focusChain))
      }
    }
  }
  private func click(_ node: Node, _ input: EventDispatcher) {
    let frame = node.absoluteFrame
    let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
    input.dispatch(.mouseButtonDown(event)); input.dispatch(.mouseButtonUp(event))
  }
  private func key(_ code: UInt32, _ input: EventDispatcher, modifiers: KeyModifiers = []) {
    input.dispatch(.keyDown(.init(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)))
  }

  @Test("Branches disclose without navigation; vertical and horizontal keys traverse only visible enabled items")
  func keyboardAndPointer() throws {
    try scene { h, graph, context, input in
      let projects = try item("projects", graph), audit = try item("audit", graph)
      #expect(!audit.acceptsSubtreeInput && projects.accessibility?.state.isExpanded == false)
      click(projects, input); settle(graph, h)
      #expect(h.expanded == ["projects"] && h.selection == "overview" && h.activations == 0)
      context.focusChain.focus(projects)
      key(Scancode.arrowRight, input); settle(graph, h)
      #expect(context.focusChain.focused === (try item("welcome", graph)) && h.selection == "welcome")
      key(Scancode.arrowDown, input); settle(graph, h)
      #expect(context.focusChain.focused === (try item("team", graph)) && h.selection == "welcome")
      key(Scancode.arrowRight, input); settle(graph, h)
      #expect(h.expanded == ["projects", "team"] && h.activations == 0)
      key(Scancode.arrowRight, input); settle(graph, h)
      #expect(context.focusChain.focused === audit && h.selection == "audit")
      key(Scancode.arrowLeft, input); settle(graph, h)
      #expect(context.focusChain.focused === (try item("team", graph)) && h.selection == "audit")
      key(Scancode.arrowLeft, input); settle(graph, h)
      #expect(!h.expanded.contains("team") && !audit.acceptsSubtreeInput && h.selection == "audit")
      #expect(nodes(graph.tree.root).filter { $0.attachments["__roving.item"] != nil && $0.isTabStop && $0.acceptsSubtreeInput }.count == 1)
      key(Scancode.arrowDown, input); settle(graph, h)
      #expect(h.selection == "settings")
      key(Scancode.home, input); settle(graph, h); #expect(h.selection == "overview")
      key(Scancode.end, input); settle(graph, h); key(Scancode.return, input); settle(graph, h)
      #expect(h.selection == "settings" && h.activations == 1)
      context.focusChain.focus(projects); key(Scancode.return, input); settle(graph, h)
      #expect(!h.expanded.contains("projects") && h.activations == 1)
    }
  }

  @Test("Programmatic selection reveals ancestors once; external collapse hands off focus without changing the page")
  func controlledDisclosure() throws {
    try scene { h, graph, context, _ in
      h.selection = "audit"; settle(graph, h)
      let audit = try item("audit", graph), projects = try item("projects", graph)
      #expect(h.expanded == ["projects", "team"] && audit.acceptsSubtreeInput)
      #expect(projects.accessibility?.state.isSelected == false)
      context.focusChain.focus(audit, visible: false)
      h.expanded.remove("projects"); settle(graph, h)
      #expect(context.focusChain.focused === projects && !context.focusChain.isFocusVisible)
      #expect(h.selection == "audit" && h.expanded == ["team"] && !audit.acceptsSubtreeInput)
      settle(graph, h); #expect(!h.expanded.contains("projects"))
      h.selection = "welcome"; settle(graph, h)
      #expect(h.expanded == ["projects", "team"])
      #expect(try item("audit", graph) === audit)
      #expect(try named("sidebar-title-audit", graph).absoluteFrame.minX > (try named("sidebar-title-projects", graph)).absoluteFrame.minX)
    }
  }

  @Test("Data removal and disabled ancestors restore a usable focus target; all descendants share the disabled state")
  func changingData() throws {
    try scene { h, graph, context, _ in
      h.selection = "audit"; settle(graph, h)
      context.focusChain.focus(try item("audit", graph)); h.removed = true; settle(graph, h)
      #expect(context.focusChain.focused === (try item("team", graph)) && h.selection == "audit")
      h.disabled = true; settle(graph, h)
      #expect(context.focusChain.focused === (try item("overview", graph)))
      for id in ["projects", "welcome", "team", "billing", "locked", "secret"] {
        let row = try item(id, graph)
        #expect(!row.isFocusable && row.accessibility?.state.isEnabled == false)
      }
      h.disabled = false; h.removed = false; h.moved = true; h.expanded = []; settle(graph, h)
      let movedAudit = try item("audit", graph)
      #expect(h.expanded == ["projects"] && movedAudit.acceptsSubtreeInput)
      graph.install(root: EmptyView()); #expect(context.focusChain.focused == nil && context.pointerCapture.target == nil)
    }
  }

  @Test("Local disclosure survives rail changes and horizontal navigation follows RTL")
  func localAndRTL() throws {
    try scene { h, graph, context, input in
      h.controlled = false; h.rtl = true; settle(graph, h)
      let projects = try item("projects", graph)
      context.focusChain.focus(projects)
      key(Scancode.arrowLeft, input); settle(graph, h)
      #expect(projects.accessibility?.state.isExpanded == true && h.expanded.isEmpty)
      key(Scancode.arrowLeft, input); settle(graph, h)
      #expect(h.selection == "welcome")
      key(Scancode.arrowRight, input); settle(graph, h)
      #expect(context.focusChain.focused === projects)
      key(Scancode.arrowRight, input, modifiers: [.shift]); settle(graph, h)
      #expect(projects.accessibility?.state.isExpanded == true)
      h.rail = true; settle(graph, h)
      #expect(try item("projects", graph) === projects)
      #expect(try item("welcome", graph).accessibility?.label == "Projects / Welcome")
      context.focusChain.focus(projects); key(Scancode.arrowRight, input); settle(graph, h)
      #expect(projects.accessibility?.state.isExpanded == false)
    }
  }

  @Test("Adaptive mode, text scale, theme, modality and direction retain disclosure, nodes, document edits and scrolling")
  func adaptiveMatrix() throws {
    try scene(adaptive: true) { h, graph, context, input in
      h.selection = "audit"; settle(graph, h)
      let audit = try item("audit", graph), projects = try item("projects", graph)
      let document = try named("hierarchy-document", graph)
      let field = try #require(nodes(try named("hierarchy-draft", graph)).first { $0.accessibility?.role == .textField })
      let scroll = try named("hierarchy-scroll", graph)
      context.focusChain.focus(field); input.dispatch(.textInput(" edited")); settle(graph, h); scroll.contentOffset.y = 60
      for width: Float in [1280, 720, 390, 1280] { for scale: Float in [1, 2] {
        for dark in [false, true] { for rtl in [false, true] {
          for modality: UIEnvironment.Input in [[.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard]] {
            h.width = width; h.scale = scale; h.dark = dark; h.rtl = rtl; h.input = modality; h.open = false; settle(graph, h)
            #expect(try item("audit", graph) === audit)
            #expect(try named("hierarchy-document", graph) === document)
            #expect(h.expanded == ["projects", "team"] && h.selection == "audit")
            #expect(context.focusChain.focused === field && field.resolvedAccessibilityValue.contains("edited") && scroll.contentOffset.y == 60)
            if width == 390 { #expect(!audit.acceptsSubtreeInput); h.open = true; settle(graph, h) }
            #expect(audit.acceptsSubtreeInput && projects.accessibility?.state.isExpanded == true)
            #expect(audit.frame.height >= (width < 1000 || modality.contains(.touch) ? 44 : 38))
            if width == 720 { #expect(audit.accessibility?.label == "Projects / Team / Audit trail") }
            if width == 390 { h.open = false; settle(graph, h); context.focusChain.focus(field) }
            #expect(!graph.recomposer.hasPending)
          }
        } }
      } }
    }
  }

  @Test("AI queries expose current expansion and omit collapsed descendants")
  func discovery() throws {
    try scene { h, graph, _, _ in
      @MainActor func query(_ text: String) throws -> Int {
        let response = UIDiagnostics(tree: graph.tree).handleReadRequest(.init(type: "diagnostics.call", payload: .object([
          "name": .string("query_ui_nodes"), "arguments": .object([
            "role": .string("button"), "text": .string(text), "visible_only": .bool(true), "input_enabled_only": .bool(true)
          ])
        ])))
        #expect(response.type == "diagnostics.call.ok")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response.payload)) as? [String: Any])
        return (json["data"] as? [String: Any])?["total"] as? Int ?? -1
      }
      #expect(try query("Audit trail") == 0)
      try item("projects", graph).accessibilityActions.activate?(); settle(graph, h)
      try item("team", graph).accessibilityActions.activate?(); settle(graph, h)
      let auditCount = try query("Audit trail")
      #expect(auditCount > 0 && h.selection == "overview")
      try item("audit", graph).accessibilityActions.activate?(); settle(graph, h)
      #expect(h.selection == "audit" && h.activations == 1)
      h.expanded.remove("projects"); settle(graph, h)
      let collapsedCount = try query("Audit trail")
      let projectsRow = try item("projects", graph)
      #expect(collapsedCount == 0 && projectsRow.accessibility?.state.isExpanded == false)
    }
  }

  @Test("Item actions open from the ellipsis and the macOS context menu")
  func itemActions() throws {
    try scene { h, graph, _, input in
      h.selection = "audit"; settle(graph, h)
      let actions = try named("sidebar-actions-audit", graph)
      click(actions, input); settle(graph, h)
      let archive = try #require(nodes(graph.tree.root).first {
        $0.accessibility?.label == "Archive" && $0.isHitTestable
      })
      click(archive, input); settle(graph, h)
      #expect(h.archived == 1)

      let audit = try item("audit", graph)
      let point = audit.absoluteFrame
      let down = MouseButtonEvent(button: .right, x: Float(point.midX), y: Float(point.midY), clicks: 1)
      input.dispatch(.mouseButtonDown(down)); input.dispatch(.mouseButtonUp(down)); settle(graph, h)
      let contextArchive = try #require(nodes(graph.tree.root).first {
        $0.accessibility?.label == "Archive" && $0.isHitTestable
      })
      click(contextArchive, input); settle(graph, h)
      #expect(h.archived == 2)
    }
  }

  @Test("Item action trigger keeps a 44pt touch target in the compact drawer")
  func compactItemActions() throws {
    try scene(adaptive: true) { h, graph, _, _ in
      h.width = 390; h.input = [.touch]; h.selection = "audit"; h.open = true; settle(graph, h)
      let actions = try named("sidebar-actions-audit", graph)
      #expect(actions.frame.height >= 44)
    }
  }
}
