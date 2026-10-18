import Foundation
import Testing
import GuavaUIRuntime
import GuavaUIAgent
import GuavaUIDevToolsProtocol
@testable import GuavaUICompose

@Suite("Resizable adaptive sidebar", .serialized)
@MainActor
struct SidebarResizeTests: GuavaUIComposeSerializedSuite {
  private struct Document: View {
    @State private var text: TextBuffer = "Retained draft"
    var body: some View {
      Column {
        TextField("Draft", text: $text).debugName("resize-draft")
        ScrollView(.vertical) { Text("Content").frame(height: 1200) }.flex(1, shrink: 1, basis: 0)
          .debugName("resize-scroll")
      }.debugName("resize-content")
    }
  }
  private final class Harness: View {
    @State var width: Float = 1280
    @State var requested: Float = 240
    @State var adjustable = true
    @State var blocked = false
    @State var selected: Int? = 1
    @State var scale: Float = 1
    @State var dark = false
    @State var rtl = false
    @State var input: UIEnvironment.Input = [.pointer, .keyboard]
    @State var alwaysExpanded = false
    var body: some View {
      var surface = UIEnvironment(); surface.viewport.width = 1280; surface.viewport.height = 600; surface.input = input
      return LayerRoot {
        AdaptiveSidebar("Workspace", selection: $selected, width: adjustable ? $requested : nil,
          sections: [SidebarSection("items", items: [SidebarItem(0, "Overview"), SidebarItem(1, "Documents")])],
          configure: {
            $0.layout.showsRailLabels = false
            if alwaysExpanded { $0.layout.compactMaximumWidth = 0; $0.layout.expandedMinimumWidth = 0 }
          }) { Document() }.allowsHitTesting(!blocked)
      }.frame(width: width, height: 600).surfaceEnvironment(surface).textScaler(.init(scale))
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
  private func handle(_ graph: ViewGraph) throws -> Node {
    try #require(nodes(graph.tree.root).first { $0.accessibility?.label == "Resize navigation" && $0.isFocusable })
  }
  private func settle(_ graph: ViewGraph, _ h: Harness) {
    for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: h.width, height: 600) }
  }
  private func scene(_ work: (Harness, ViewGraph, PlatformInputContext, EventDispatcher) throws -> Void) rethrows {
    try GlobalTestLock.locked {
      let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
      defer { TextEnvironmentHolder.current = old }
      let context = PlatformInputContext(), portals = PortalStore()
      context.addScopedAmbient(PortalStoreAmbient(portals))
      try context.withCurrent {
        let h = Harness(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                    capture: context.pointerCapture, focusChain: context.focusChain)
        graph.install(root: h); settle(graph, h)
        defer { graph.install(root: EmptyView()) }
        try work(h, graph, context, input)
      }
    }
  }
  private func pointer(_ node: Node, _ input: EventDispatcher, down: Bool, button: MouseButton = .left) {
    let f = node.absoluteFrame, event = MouseButtonEvent(button: button, x: Float(f.midX), y: Float(f.midY), clicks: 1)
    input.dispatch(down ? .mouseButtonDown(event) : .mouseButtonUp(event))
  }
  private func motion(x: Float, _ input: EventDispatcher) {
    input.dispatch(.mouseMotion(.init(x: x, y: 300, deltaX: 0, deltaY: 0)))
  }
  private func key(_ code: UInt32, _ input: EventDispatcher, modifiers: KeyModifiers = []) {
    input.dispatch(.keyDown(.init(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)))
  }

  @Test("Resize defaults validate independently and fixed bounds expose no useless handle")
  func limits() {
    var limits = SidebarResizeOptions()
    limits.minimumWidth = .nan; limits.maximumWidth = .infinity; limits.minimumContentWidth = .nan
    limits.validate()
    #expect(limits.minimumWidth == 180 && limits.maximumWidth == 480 && limits.minimumContentWidth == 320)
    limits.minimumWidth = 500; limits.maximumWidth = 100; limits.minimumContentWidth = -20
    limits.validate()
    #expect(limits.maximumWidth == 500 && limits.minimumContentWidth == 44)
    var policy = SidebarLayoutPolicy(); policy.compactMaximumWidth = 0; policy.expandedMinimumWidth = 0
    let fixed = SidebarGeometry(width: 1000, policy: policy, isPresented: false,
                               requestedWidth: 900, resizing: limits)
    #expect(fixed.resizeHandleWidth == 0 && fixed.dockedWidth == 500)
  }

  @Test("An explicitly bounded sidebar keeps its height and cannot collapse adjacent story content")
  func embeddedHeight() throws {
    try scene { h, graph, _, _ in
      var surface = UIEnvironment(); surface.input = [.touch, .keyboard]; surface.viewport.width = 1280
      graph.install(root: LayerRoot {
        Column(alignment: .leading, spacing: 12) {
          AdaptiveSidebar("Embedded", selection: h.$selected, width: h.$requested,
            sections: [SidebarSection("items", items: [SidebarItem(0, "Overview"), SidebarItem(1, "Documents")])],
            configure: { $0.layout.expandedMinimumWidth = 600 }) { Document() }
            .frame(width: 720, height: 220).debugName("bounded-sidebar")
          Text("After navigation").debugName("after-navigation")
        }
      }.frame(width: 1280, height: 600).surfaceEnvironment(surface).textScaler(.init(2)))
      settle(graph, h)
      let shell = try named("bounded-sidebar", graph), resize = try handle(graph)
      #expect(abs(shell.frame.height - 220) < 1 && abs(resize.frame.height - 220) < 1)
      #expect(try named("after-navigation", graph).absoluteFrame.minY >= shell.absoluteFrame.maxY + 11)
      let first = try #require(nodes(graph.tree.root).first { $0.isFocusable && $0.accessibility?.label == "Overview" })
      let second = try #require(nodes(graph.tree.root).first { $0.isFocusable && $0.accessibility?.label == "Documents" })
      #expect(second.absoluteFrame.minY >= first.absoluteFrame.maxY)
    }
  }

  @Test("Width fitting follows the container, input and direction while retaining the document and request")
  func matrix() throws {
    try scene { h, graph, context, input in
      h.requested = 320; settle(graph, h)
      let resizer = try handle(graph), document = try named("resize-content", graph)
      let field = try #require(nodes(try named("resize-draft", graph)).first { $0.accessibility?.role == .textField })
      let scroll = try named("resize-scroll", graph)
      context.focusChain.focus(field); input.dispatch(.textInput(" edited")); settle(graph, h)
      scroll.contentOffset.y = 80
      for width: Float in [1280, 720, 390, 1000, 1280] { for scale: Float in [1, 2] {
        for modality: UIEnvironment.Input in [[.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard]] {
          for dark in [false, true] { for rtl in [false, true] {
            h.width = width; h.scale = scale; h.input = modality; h.dark = dark; h.rtl = rtl; settle(graph, h)
            #expect(try named("resize-content", graph) === document)
            #expect(context.focusChain.focused === field && field.resolvedAccessibilityValue.contains("edited"))
            #expect(h.requested == 320 && h.selected == 1 && scroll.contentOffset.y == 80)
            let navigation: CGFloat = width >= 1000 ? 320 : width >= 600 ? 56 : 0
            let lane: CGFloat = width >= 1000 ? (modality.contains(.touch) ? 44 : 7) : 0
            #expect(abs(document.frame.width - CGFloat(width) + navigation + lane) < 1)
            if rtl { #expect(abs(document.absoluteFrame.maxX - CGFloat(width) + navigation + lane) < 1) }
            else { #expect(abs(document.absoluteFrame.minX - navigation - lane) < 1) }
            if width >= 1000 {
              #expect(try handle(graph) === resizer)
              #expect(abs(resizer.frame.width - lane) < 1 && resizer.frame.height >= 44)
              #expect(resizer.accessibility?.value == "320 pt")
            } else { #expect(!resizer.isFocusable && !resizer.isHitTestable && resizer.accessibility == nil) }
            #expect(!graph.recomposer.hasPending)
          } }
        }
      } }
    }
  }

  @Test("Dragging captures outside the lane, cancellation restores the starting width and keys share the bounds")
  func dragAndKeyboard() throws {
    try scene { h, graph, context, input in
      let resize = try handle(graph), start = Float(resize.absoluteFrame.midX)
      pointer(resize, input, down: true, button: .right); #expect(context.pointerCapture.target == nil)
      pointer(resize, input, down: true)
      #expect(context.pointerCapture.target === resize && !context.focusChain.isFocusVisible)
      motion(x: start + 100, input); settle(graph, h)
      #expect(h.requested == 340 && context.pointerCapture.target === resize)
      motion(x: start - 500, input); settle(graph, h); #expect(h.requested == 180)
      key(Scancode.escape, input); settle(graph, h)
      #expect(h.requested == 240 && context.pointerCapture.target == nil)
      context.focusChain.focus(resize)
      key(Scancode.arrowRight, input); settle(graph, h); #expect(h.requested == 256)
      key(Scancode.arrowRight, input, modifiers: [.shift]); settle(graph, h); #expect(h.requested == 288)
      key(Scancode.arrowLeft, input); settle(graph, h); #expect(h.requested == 272)
      key(Scancode.end, input); settle(graph, h); #expect(h.requested == 480)
      key(Scancode.home, input); settle(graph, h); #expect(h.requested == 180)
      key(Scancode.arrowRight, input, modifiers: [.ctrl]); #expect(h.requested == 180)
      resize.accessibilityActions.increment?(); resize.accessibilityActions.increment?(); settle(graph, h)
      #expect(h.requested == 212)
      resize.accessibilityActions.decrement?(); settle(graph, h); #expect(h.requested == 196)
      resize.accessibilityActions.setValue?("260 pt"); settle(graph, h); #expect(h.requested == 260)
      resize.accessibilityActions.setValue?("nan"); settle(graph, h); #expect(h.requested == 260)
    }
  }

  @Test("RTL dragging grows leftward; shape, mode, input disabling and teardown release captures")
  func lifecycle() throws {
    try scene { h, graph, context, input in
      h.rtl = true; h.requested = 320; settle(graph, h)
      let resize = try handle(graph), x = Float(resize.absoluteFrame.midX)
      pointer(resize, input, down: true)
      #expect(context.pointerCapture.target === resize,
              "actual capture: \(context.pointerCapture.target?.accessibility?.label ?? "none"), frame \(context.pointerCapture.target?.absoluteFrame ?? .zero); handle \(resize.absoluteFrame)")
      motion(x: x - 48, input); settle(graph, h)
      #expect(h.requested == 368)
      h.width = 720; settle(graph, h)
      #expect(context.pointerCapture.target == nil && h.requested == 368)
      #expect(context.focusChain.focused?.accessibility?.label == "Documents")
      h.width = 1280; settle(graph, h); #expect(try handle(graph) === resize)
      pointer(resize, input, down: true); h.width = 390; settle(graph, h)
      #expect(context.pointerCapture.target == nil && context.focusChain.focused?.accessibility?.label == "Open navigation")
      h.width = 1280; settle(graph, h)
      pointer(resize, input, down: true); h.input = [.touch, .keyboard]; settle(graph, h)
      #expect(context.pointerCapture.target == nil && resize.frame.width == 44)
      pointer(resize, input, down: true); h.blocked = true; settle(graph, h)
      #expect(context.pointerCapture.target == nil && context.focusChain.focused == nil && !resize.acceptsSubtreeInput)
      h.blocked = false; settle(graph, h)
      pointer(resize, input, down: true); h.adjustable = false; settle(graph, h)
      #expect(context.pointerCapture.target == nil && !resize.isFocusable)
      h.adjustable = true; settle(graph, h); pointer(resize, input, down: true)
      graph.install(root: EmptyView())
      #expect(context.pointerCapture.target == nil && context.focusChain.focused == nil)
    }
  }

  @Test("Temporary constraints and invalid requests never overwrite authored widths during layout")
  func fittingAndAI() throws {
    try scene { h, graph, _, input in
      h.alwaysExpanded = true; h.requested = 400; h.width = 500; settle(graph, h)
      #expect(h.requested == 400)
      #expect(abs((try named("resize-content", graph)).frame.width - 320) < 1)
      #expect(!nodes(graph.tree.root).contains { $0.accessibility?.label == "Resize navigation" })
      h.width = 640; settle(graph, h)
      let resize = try handle(graph)
      #expect(h.requested == 400 && resize.accessibility?.value == "313 pt")
      h.width = 1280; settle(graph, h); #expect(resize.accessibility?.value == "400 pt")
      h.requested = .nan; settle(graph, h)
      #expect(h.requested.isNaN && resize.accessibility?.value == "240 pt")
      resize.accessibilityActions.increment?(); settle(graph, h); #expect(h.requested == 256)
      let diagnostic = UIDiagnostics(tree: graph.tree)
      let response = diagnostic.handleReadRequest(.init(type: "diagnostics.call", payload: .object([
        "name": .string("query_ui_nodes"), "arguments": .object([
          "role": .string("slider"), "text": .string("256 pt"), "visible_only": .bool(true), "input_enabled_only": .bool(true)
        ])
      ])))
      #expect(response.type == "diagnostics.call.ok")
      let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response.payload)) as? [String: Any])
      #expect((json["data"] as? [String: Any])?["total"] as? Int == 1)
      pointer(resize, input, down: true); pointer(resize, input, down: false)
    }
  }
}
