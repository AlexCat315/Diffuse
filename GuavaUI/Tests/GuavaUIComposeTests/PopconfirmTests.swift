import Foundation
import Testing
import GuavaUIRuntime
import GuavaUIAgent
import GuavaUIDevToolsProtocol
@testable import GuavaUICompose

@Suite("Popconfirm", .serialized)
@MainActor
struct PopconfirmTests: GuavaUIComposeSerializedSuite {
  private final class Harness: View {
    @State var count = 0
    @State var mounted = true
    @State var enabled = true
    @State var placement = PopoverPlacement.bottom
    @State var width: Float = 640
    @State var height: Float = 480
    @State var x: Float = 220
    @State var y: Float = 200
    @State var scale: Float = 1
    @State var dark = false
    @State var rtl = false
    @State var input: UIEnvironment.Input = [.pointer, .keyboard]
    @State var title = "Delete this project?"
    var body: some View {
      var surface = UIEnvironment(); surface.viewport.width = width; surface.viewport.height = height; surface.input = input
      return LayerRoot {
        if mounted {
          Popconfirm("Delete project", icon: UIIcons.Action.trash, title: title,
                     message: "This removes the project and its local history.", confirmTitle: "Remove",
                     cancelTitle: "Keep", role: .destructive, placement: placement, isEnabled: enabled) { self.count += 1 }
            .absolutePosition(left: x, top: y)
        }
      }.frame(width: width, height: height).surfaceEnvironment(surface).textScaler(.init(scale))
        .appearance(dark ? .dark : .light).layoutDirection(rtl ? .rtl : .ltr).reducedMotion()
    }
  }
  private struct SharedCardScene: View {
    @State private var open = true
    var body: some View {
      LayerRoot {
        Popover(isPresented: $open, width: 300, placement: .top, label: { Text("Open details") }) {
          Text("Shared surface")
          Button("Done") { open = false }.accessibilityLabel("Done")
        }.absolutePosition(left: 220, top: 240)
      }.frame(width: 640, height: 480).reducedMotion()
    }
  }
  private func nodes(_ root: Node?) -> [Node] {
    var pending = root.map { [$0] } ?? [], result: [Node] = []
    while let node = pending.popLast() { result.append(node); pending.append(contentsOf: node.children.reversed()) }
    return result
  }
  private func button(_ label: String, _ graph: ViewGraph) throws -> Node {
    try #require(nodes(graph.tree.root).first { $0.accessibility?.label == label && $0.accessibility?.role == .button })
  }
  private func panel(_ graph: ViewGraph) throws -> Node {
    try #require(nodes(graph.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "anchored-surface" })
  }
  private func settle(_ graph: ViewGraph, _ h: Harness) {
    for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: h.width, height: h.height) }
  }
  private func scene(_ work: (Harness, ViewGraph, PlatformInputContext, PortalStore, EventDispatcher) throws -> Void) rethrows {
    try GlobalTestLock.locked {
      let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
      defer { TextEnvironmentHolder.current = old }
      let context = PlatformInputContext(), portals = PortalStore()
      context.addScopedAmbient(PortalStoreAmbient(portals))
      try context.withCurrent {
        try AnimatorScheduler.$current.withValue(AnimatorScheduler()) {
          let h = Harness(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
          graph.install(root: h); settle(graph, h)
          defer { graph.install(root: EmptyView()) }
          try work(h, graph, context, portals, EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                                              capture: context.pointerCapture, focusChain: context.focusChain))
        }
      }
    }
  }
  private func click(_ node: Node, _ input: EventDispatcher) {
    let frame = node.absoluteFrame
    let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
    input.dispatch(.mouseButtonDown(event)); input.dispatch(.mouseButtonUp(event))
  }
  private func key(_ code: UInt32, _ input: EventDispatcher, modifiers: KeyModifiers = []) {
    let event = KeyEvent(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)
    input.dispatch(.keyDown(event)); input.dispatch(.keyUp(event))
  }

  @Test("Confirm executes once, cancel and dismissal do not, and keyboard focus returns to the trigger")
  func lifecycle() throws {
    try scene { h, graph, context, portals, input in
      let trigger = try button("Delete project", graph)
      context.focusChain.focus(trigger); key(Scancode.return, input); settle(graph, h)
      let keep = try button("Keep", graph), remove = try button("Remove", graph)
      #expect(trigger.accessibility?.state.isExpanded == true && context.focusChain.focused === keep)
      key(Scancode.tab, input); settle(graph, h); #expect(context.focusChain.focused === remove)
      key(Scancode.tab, input); settle(graph, h); #expect(context.focusChain.focused === keep)
      key(Scancode.return, input); settle(graph, h)
      #expect(h.count == 0 && portals.entries.isEmpty && context.focusChain.focused === trigger)
      click(trigger, input); settle(graph, h)
      let confirm = try button("Remove", graph).accessibilityActions.activate
      confirm?(); confirm?(); settle(graph, h)
      #expect(h.count == 1 && portals.entries.isEmpty && trigger.accessibility?.state.isExpanded == false)
      click(trigger, input); settle(graph, h); key(Scancode.escape, input); settle(graph, h)
      #expect(h.count == 1 && portals.entries.isEmpty && context.focusChain.focused === trigger)
      click(trigger, input); settle(graph, h)
      let outside = MouseButtonEvent(button: .left, x: 12, y: 12, clicks: 1)
      input.dispatch(.mouseButtonDown(outside)); input.dispatch(.mouseButtonUp(outside)); settle(graph, h)
      #expect(portals.entries.isEmpty && h.count == 1)
      click(trigger, input); settle(graph, h); click(trigger, input); settle(graph, h)
      #expect(portals.entries.isEmpty && h.count == 1)
    }
  }

  @Test("All placements respect logical direction, flip at edges and remain within the viewport")
  func placements() {
    let window = CGRect(x: 0, y: 0, width: 1280, height: 900), size = CGSize(width: 300, height: 180)
    let center = CGRect(x: 600, y: 400, width: 80, height: 44)
    for placement in PopoverPlacement.allCases { for rtl in [false, true] {
      let layout = PopoverGeometry(anchor: center, size: size, window: window, placement: placement, rtl: rtl)
      let expected = rtl && !placement.edge.isVertical ? placement.edge.opposite : placement.edge
      #expect(layout.edge == expected && window.insetBy(dx: 8, dy: 8).contains(layout.frame))
      for anchor in [CGRect(x: 8, y: 8, width: 44, height: 44), CGRect(x: 1228, y: 848, width: 44, height: 44)] {
        let edge = PopoverGeometry(anchor: anchor, size: size, window: window, placement: placement, rtl: rtl)
        #expect(window.insetBy(dx: 8, dy: 8).contains(edge.frame))
      }
    } }
    let bottom = PopoverGeometry(anchor: CGRect(x: 220, y: 850, width: 80, height: 44), size: size,
                                    window: window, placement: .bottom, rtl: false)
    #expect(bottom.edge == .bottom && bottom.frame.height == 0)
    let right = PopoverGeometry(anchor: CGRect(x: 1228, y: 400, width: 44, height: 44), size: size,
                                   window: window, placement: .trailing, rtl: false)
    #expect(right.edge == .right && right.frame.width == 0)
    let adaptive = PopoverGeometry(anchor: CGRect(x: 220, y: 850, width: 80, height: 44), size: size,
                                   window: window, placement: .bottom, rtl: false, overflow: .flip)
    #expect(adaptive.edge == .top && adaptive.frame.maxY < 850)
  }

  @Test("Three widths, scaled text, themes, direction and input keep real buttons inside an opaque painted bubble")
  func matrixAndPainting() throws {
    try scene { h, graph, _, portals, _ in
      try button("Delete project", graph).accessibilityActions.activate?(); settle(graph, h)
      for width: Float in [390, 720, 1280] { for scale: Float in [1, 2] {
        for dark in [false, true] { for rtl in [false, true] {
          for modality: UIEnvironment.Input in [[.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard]] {
            h.width = width; h.height = 820; h.x = width - 160; h.y = 40; h.scale = scale
            h.dark = dark; h.rtl = rtl; h.input = modality; h.placement = .bottomTrailing; settle(graph, h)
            let surface = try panel(graph), keep = try button("Keep", graph), remove = try button("Remove", graph)
            let frame = surface.absoluteFrame
            #expect(frame.minX >= 8 && frame.maxX <= CGFloat(width) - 8 && frame.maxY <= 812)
            let body = frame.insetBy(dx: 10, dy: 10)
            #expect(body.contains(keep.absoluteFrame) && body.contains(remove.absoluteFrame))
            #expect(!keep.absoluteFrame.intersects(remove.absoluteFrame))
            if rtl { #expect(keep.absoluteFrame.minX >= remove.absoluteFrame.maxX) }
            else { #expect(keep.absoluteFrame.maxX <= remove.absoluteFrame.minX) }
            #expect(keep.frame.height >= (modality.contains(.touch) ? 44 : 32))
            #expect(remove.frame.height >= (modality.contains(.touch) ? 44 : 32))
            #expect(nodes(graph.tree.root).contains { $0.accessibility?.role == .dialog && $0.accessibility?.label == h.title })
            #expect(portals.entries.count == 1 && !graph.recomposer.hasPending)
            let list = DrawList(), origin = CGPoint(x: 600, y: 300)
            surface.draw?(list, origin)
            let fill = surface.theme.colors.surfaceFloating.rgba8
            let vertices = list.vertices.filter { $0.color == fill }
            #expect(surface.theme.colors.surfaceFloating.a == 1 && vertices.count > 10)
            #expect(vertices.allSatisfy { $0.posX >= 600 && $0.posY >= 300 && $0.posX <= 600 + Float(frame.width) && $0.posY <= 300 + Float(frame.height) })
          }
        } }
      } }
    }
  }

  @Test("Open content updates immediately; disabling and teardown remove portals and focus")
  func updatesAndTeardown() throws {
    try scene { h, graph, context, portals, input in
      let trigger = try button("Delete project", graph)
      click(trigger, input); settle(graph, h)
      h.title = "Remove the archived workspace?"; h.dark = true; h.scale = 2; settle(graph, h)
      #expect(nodes(graph.tree.root).contains { $0.accessibility?.role == .dialog && $0.accessibility?.label == h.title })
      #expect(portals.entries.count == 1)
      h.enabled = false; settle(graph, h)
      #expect(portals.entries.isEmpty && trigger.accessibility?.state.isExpanded == false && !trigger.isFocusable)
      h.enabled = true; settle(graph, h); click(trigger, input); settle(graph, h)
      #expect(portals.entries.count == 1)
      h.mounted = false; settle(graph, h)
      #expect(portals.entries.isEmpty && context.pointerCapture.target == nil && context.focusChain.focused == nil)
    }
  }

  @Test("AI tools discover the dialog and action labels and follow its dismissal")
  func discovery() throws {
    try scene { h, graph, _, _, _ in
      @MainActor func query(role: String, text: String) throws -> Int {
        let response = UIDiagnostics(tree: graph.tree).handleReadRequest(.init(type: "diagnostics.call", payload: .object([
          "name": .string("query_ui_nodes"), "arguments": .object([
            "role": .string(role), "text": .string(text), "visible_only": .bool(true), "input_enabled_only": .bool(true)
          ])
        ])))
        #expect(response.type == "diagnostics.call.ok")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response.payload)) as? [String: Any])
        return (json["data"] as? [String: Any])?["total"] as? Int ?? -1
      }
      #expect(try query(role: "dialog", text: h.title) == 0)
      try button("Delete project", graph).accessibilityActions.activate?(); settle(graph, h)
      #expect(try query(role: "dialog", text: h.title) == 1)
      #expect(try query(role: "button", text: "Remove") == 1)
      try button("Keep", graph).accessibilityActions.activate?(); settle(graph, h)
      #expect(try query(role: "dialog", text: h.title) == 0 && h.count == 0)
    }
  }

  @Test("Every explicit side is retained by the actual portal, including RTL and constrained widths")
  func namedSides() throws {
    try scene { h, graph, _, _, _ in
      try button("Delete project", graph).accessibilityActions.activate?(); settle(graph, h)
      for placement in PopoverPlacement.allCases { for rtl in [false, true] {
        h.placement = placement; h.rtl = rtl; settle(graph, h)
        let trigger = try button("Delete project", graph).absoluteFrame, surface = try panel(graph).absoluteFrame
        let edge = rtl && !placement.edge.isVertical ? placement.edge.opposite : placement.edge
        switch edge {
        case .top: #expect(surface.maxY <= trigger.minY - 3)
        case .bottom: #expect(surface.minY >= trigger.maxY + 3)
        case .left: #expect(surface.maxX <= trigger.minX - 3)
        case .right: #expect(surface.minX >= trigger.maxX + 3)
        }
      } }
    }
  }

  @Test("Generic Popover uses the same bubble surface with no caller-owned card")
  func sharedCard() throws {
    try scene { h, graph, _, portals, _ in
      graph.install(root: SharedCardScene())
      settle(graph, h)
      let surface = try panel(graph)
      #expect(surface.frame.width == 300 && surface.absoluteFrame.maxY <= 237)
      #expect(surface.draw != nil && portals.entries.count == 1)
      try button("Done", graph).accessibilityActions.activate?(); settle(graph, h)
      #expect(portals.entries.isEmpty)
    }
  }
}
