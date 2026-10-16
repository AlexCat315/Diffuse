import Foundation
import GuavaUIAgent
import GuavaUIRuntime
import Testing

@testable import GuavaUICompose

@Suite("Adaptive sidebar shell", .serialized)
@MainActor
struct AdaptiveSidebarTests: GuavaUIComposeSerializedSuite {
  private struct Header: View {
    @State private var visits = 0
    var body: some View {
      Button("H \(visits)") { visits += 1 }.accessibilityLabel("Header \(visits)")
        .frame(minHeight: 44).debugName("adaptive-header")
    }
  }
  private struct Content: View {
    @State private var draft: TextBuffer = "Local draft"
    @State private var count = 0
    var body: some View {
      Box(direction: .column, alignItems: .stretch) {
        Button("Background \(count)") { count += 1 }.accessibilityLabel("Background \(count)")
          .frame(minHeight: 44).debugName("adaptive-background")
        TextField("Document draft", text: $draft).debugName("adaptive-draft")
        ScrollView(.vertical) { Text("Document content").frame(height: 1000) }
          .flex(1, shrink: 1, basis: 0).debugName("adaptive-scroll")
      }.debugName("adaptive-content")
    }
  }
  private final class Harness: View {
    @State var width: Float = 1280
    @State var height: Float = 640
    @State var open = false
    @State var selected: Int? = 29
    @State var scale: Float = 1
    @State var dark = false
    @State var input: UIEnvironment.Input = [.pointer, .keyboard]
    @State var reduced = true
    @State var edge = true
    @State var closesOnSelection = true
    @State var closesOnBackdrop = true
    @State var closesOnEscape = true
    @State var compact: Float = 600
    @State var expanded: Float = 1000
    @State var railLabels = true
    let localPresentation: Bool
    init(localPresentation: Bool = false) { self.localPresentation = localPresentation }
    var body: some View {
      var surface = UIEnvironment()
      surface.input = input
      surface.viewport.width = 1280  // Allocation must win over surface metadata.
      return LayerRoot {
        AdaptiveSidebar(
          "Workspace", isPresented: localPresentation ? nil : $open,
          selection: $selected,
          sections: [
            SidebarSection(
              "destinations", title: "Destinations",
              items: (0..<30).map { index in
                SidebarItem(index, "Destination \(index)") {
                  $0.isEnabled = index != 2
                  $0.icon = UIIcons.File.folder
                }
              })
          ],
          configure: {
            $0.allowsEdgeSwipe = edge
            $0.drawer.closesOnSelection = closesOnSelection
            $0.drawer.dismissal.closesOnBackdrop = closesOnBackdrop
            $0.drawer.dismissal.closesOnEscape = closesOnEscape
            $0.layout.compactMaximumWidth = compact
            $0.layout.expandedMinimumWidth = expanded
            $0.layout.showsRailLabels = railLabels
          }, header: { Header() }, footer: { Text("Footer").font(.caption) }
        ) { Content() }
        .flex(1, shrink: 1, basis: 0)
      }.surfaceEnvironment(surface).textScaler(.init(scale)).appearance(dark ? .dark : .light)
        .reducedMotion(reduced)
    }
  }
  private func nodes(_ root: Node?) -> [Node] {
    var pending = root.map { [$0] } ?? []
    var result: [Node] = []
    while let node = pending.popLast() {
      result.append(node)
      pending.append(contentsOf: node.children.reversed())
    }
    return result
  }
  private func named(_ name: String, _ graph: ViewGraph) throws -> Node {
    try #require(
      nodes(graph.tree.root).first {
        $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name
      })
  }
  private func field(_ graph: ViewGraph) throws -> Node {
    try #require(
      nodes(try named("adaptive-draft", graph)).first {
        $0.isFocusable && $0.accessibility?.role == .textField
      })
  }
  private func navigation(_ graph: ViewGraph) throws -> Node {
    try #require(nodes(graph.tree.root).first { $0.accessibility?.label == "Workspace" })
  }
  private func opener(_ graph: ViewGraph) throws -> Node {
    try #require(
      nodes(graph.tree.root).first {
        $0.accessibility?.label == "Open navigation" && $0.isFocusable && $0.acceptsSubtreeInput
      })
  }
  private func settle(_ graph: ViewGraph, _ harness: Harness) {
    for _ in 0..<10 {
      graph.recomposer.commitAll()
      graph.computeLayout(width: harness.width, height: harness.height)
    }
  }
  private func scene(
    localPresentation: Bool = false,
    _ work: (Harness, ViewGraph, PlatformInputContext, EventDispatcher, AnimatorScheduler) throws ->
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
          let harness = Harness(localPresentation: localPresentation)
          let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
          let input = EventDispatcher(
            tree: graph.tree, interactions: context.interactions,
            capture: context.pointerCapture, focusChain: context.focusChain)
          graph.install(root: harness)
          settle(graph, harness)
          defer {
            graph.install(root: EmptyView())
            scheduler.reset()
          }
          try work(harness, graph, context, input, scheduler)
        }
      }
    }
  }
  private func key(_ code: UInt32, _ input: EventDispatcher) {
    input.dispatch(.keyDown(.init(scancode: code, keycode: 0, modifiers: [], isRepeat: false)))
  }
  private func click(_ node: Node, _ input: EventDispatcher) {
    let frame = node.absoluteFrame
    let event = MouseButtonEvent(
      button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
    input.dispatch(.mouseButtonDown(event))
    input.dispatch(.mouseButtonUp(event))
  }

  @Test(
    "Allocated breakpoints, dialog geometry and 44pt targets across input, theme and 200 percent text"
  )
  func geometry() throws {
    try scene { harness, graph, _, _, _ in
      let original = try named("sidebar-item-29", graph).id
      let diagnostics = UIDiagnostics(tree: graph.tree)
      for scale: Float in [1, 2] {
        for input: UIEnvironment.Input in [
          [.pointer, .keyboard], [.touch], [.touch, .pointer, .keyboard],
        ] {
          for dark in [false, true] {
            for width: Float in [390, 720, 1280] {
              harness.scale = scale
              harness.input = input
              harness.dark = dark
              harness.width = width
              harness.open = false
              settle(graph, harness)
              let main = try named("adaptive-content", graph)
              let row = try named("sidebar-item-29", graph)
              #expect(row.id == original)
              #expect(
                main.frame.width
                  == CGFloat(width < 600 ? width : width < 1000 ? width - 72 : width - 240))
              #expect(main.frame.height > 400 && main.absoluteFrame.maxX <= CGFloat(width))
              #expect(row.acceptsSubtreeInput == (width >= 600))
              if width < 1000 {
                let trigger = try opener(graph)
                #expect(trigger.frame.width >= 44 && trigger.frame.height >= 44)
                trigger.accessibilityActions.activate?()
                settle(graph, harness)
                let panel = try navigation(graph)
                #expect(panel.accessibility?.role == .dialog)
                #expect(panel.frame.width == min(320, CGFloat(width - 56)))
                #expect(panel.frame.height == CGFloat(harness.height))
                #expect(main.frame.width == CGFloat(width == 390 ? width : width - 72))
                #expect(row.frame.height >= 44)
                let found = try diagnostics.queryNodes(
                  text: "Destination 29", role: "button", visibleOnly: true, inputEnabledOnly: true)
                #expect(found.total == 1)
                let background = try diagnostics.queryNodes(
                  text: "Background", role: "button", inputEnabledOnly: true)
                #expect(background.total == 0)
              } else {
                #expect(try navigation(graph).accessibility?.role == .group)
                #expect(row.frame.height >= (input.contains(.touch) ? 44 : 38))
              }
              #expect(!graph.recomposer.hasPending)
            }
          }
        }
      }
    }
  }

  @Test(
    "Navigation slots, page drafts, counters and scroll survive open, close and all presentations")
  func retention() throws {
    try scene { harness, graph, context, input, _ in
      let row = try named("sidebar-item-29", graph)
      let field = try field(graph)
      let header = try named("adaptive-header", graph)
      let scroll = try named("adaptive-scroll", graph)
      header.accessibilityActions.activate?()
      context.focusChain.focus(field)
      input.dispatch(.textInput("Edited "))
      settle(graph, harness)
      let draft = field.resolvedAccessibilityValue
      #expect(draft.contains("Edited "))
      scroll.contentOffset.y = 180
      for (width, open): (Float, Bool) in [
        (720, false), (390, false), (390, true), (1280, true), (720, true), (390, false),
        (1280, false),
      ] {
        harness.width = width
        harness.open = open
        settle(graph, harness)
        #expect(row.id == (try named("sidebar-item-29", graph)).id)
        #expect(field.id == (try self.field(graph)).id)
        #expect(
          header.id == (try named("adaptive-header", graph)).id
            && header.accessibility?.label == "Header 1")
        #expect(field.resolvedAccessibilityValue == draft && scroll.contentOffset.y == 180)
        #expect(harness.selected == 29)
      }
      harness.width = 390
      harness.open = true
      settle(graph, harness)
      harness.width = 1280
      settle(graph, harness)
      let dockedRole = try navigation(graph).accessibility?.role
      #expect(harness.open && dockedRole == .group)
      harness.width = 390
      settle(graph, harness)
      let modalRole = try navigation(graph).accessibility?.role
      #expect(harness.open && modalRole == .dialog)
    }
  }

  @Test(
    "Focus hands off at breakpoints, modal input is blocked, Escape restores the opener and captures cancel"
  )
  func focusAndInput() throws {
    try scene { harness, graph, context, input, _ in
      let row = try named("sidebar-item-29", graph)
      context.focusChain.focus(row, visible: false)
      harness.width = 720
      settle(graph, harness)
      #expect(context.focusChain.focused?.id == row.id && !context.focusChain.isFocusVisible)
      harness.width = 390
      settle(graph, harness)
      let trigger = try opener(graph)
      #expect(context.focusChain.focused?.id == trigger.id && !context.focusChain.isFocusVisible)
      context.focusChain.focus(trigger)
      click(trigger, input)
      settle(graph, harness)
      #expect(harness.open && context.focusChain.hasModalScope)
      let background = try named("adaptive-background", graph)
      click(background, input)
      settle(graph, harness)
      #expect(background.accessibility?.label == "Background 0")
      context.focusChain.focus(row)
      key(Scancode.home, input)
      key(Scancode.arrowDown, input)
      key(Scancode.arrowDown, input)
      settle(graph, harness)
      #expect(harness.selected == 3 && harness.open)
      key(Scancode.escape, input)
      settle(graph, harness)
      #expect(!harness.open && !context.focusChain.hasModalScope)
      #expect(context.focusChain.focused?.id == trigger.id)
      harness.width = 1280
      settle(graph, harness)
      let selected = try named("sidebar-item-3", graph)
      #expect(context.focusChain.focused?.id == selected.id)
      let frame = selected.absoluteFrame
      input.dispatch(
        .mouseButtonDown(
          .init(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)))
      #expect(context.pointerCapture.target != nil)
      harness.width = 390
      settle(graph, harness)
      #expect(context.pointerCapture.target == nil)
    }
  }

  @Test("Pointer and accessibility activation restore the compact or rail opener after modal slots change visibility")
  func openerRestoration() throws {
    try scene { harness, graph, context, input, _ in
      for width: Float in [390, 720] {
        harness.width = width; settle(graph, harness)
        let trigger = try opener(graph)
        for semantic in [false, true] {
          context.focusChain.clear()
          if semantic { trigger.accessibilityActions.activate?() }
          else { click(trigger, input) }
          settle(graph, harness)
          #expect(harness.open && context.focusChain.hasModalScope)
          key(Scancode.escape, input); settle(graph, harness)
          #expect(!harness.open && !context.focusChain.hasModalScope)
          #expect(context.focusChain.focused?.id == trigger.id)
        }
      }
    }
  }

  @Test(
    "Optional leading-edge touch gesture cancels taps, respects direction and leaves non-edge content alone"
  )
  func edgeGesture() throws {
    try scene { harness, graph, _, input, _ in
      harness.width = 390
      harness.input = [.touch]
      settle(graph, harness)
      let background = try named("adaptive-background", graph)
      let y = Float(background.absoluteFrame.midY)
      @MainActor func swipe(_ x: Float, _ dx: Float, _ dy: Float = 0) {
        input.dispatch(.mouseButtonDown(.init(button: .left, x: x, y: y, clicks: 1)))
        input.dispatch(.mouseMotion(.init(x: x + dx, y: y + dy, deltaX: dx, deltaY: dy)))
        input.dispatch(.mouseButtonUp(.init(button: .left, x: x + dx, y: y + dy, clicks: 1)))
        settle(graph, harness)
      }
      swipe(10, 100)
      #expect(harness.open && background.accessibility?.label == "Background 0")
      swipe(200, -160)
      #expect(!harness.open)
      swipe(50, 100)
      #expect(!harness.open)
      swipe(10, 10, 90)
      #expect(!harness.open)
      harness.input = [.pointer, .keyboard]
      settle(graph, harness)
      swipe(10, 100)
      #expect(!harness.open)
    }
  }

  @Test(
    "Local presentation, policy validation and modal-to-docked focus retain a single navigation tree"
  )
  func localSessionAndPolicy() throws {
    try scene(localPresentation: true) { harness, graph, context, _, _ in
      harness.width = 390
      settle(graph, harness)
      try opener(graph).accessibilityActions.activate?()
      settle(graph, harness)
      let row = try named("sidebar-item-29", graph)
      context.focusChain.focus(row)
      harness.width = 1280
      settle(graph, harness)
      #expect(!context.focusChain.hasModalScope && context.focusChain.focused?.id == row.id)
      harness.width = 390
      settle(graph, harness)
      #expect(context.focusChain.hasModalScope)
      harness.width = 720
      harness.compact = 800
      harness.expanded = 900
      settle(graph, harness)
      #expect(try navigation(graph).frame.width == 320)
      harness.width = 850
      harness.railLabels = false
      settle(graph, harness)
      // The retained local session is open, so medium navigation remains a drawer.
      #expect(try navigation(graph).accessibility?.role == .dialog)
      var policy = SidebarLayoutPolicy()
      policy.compactMaximumWidth = .nan
      policy.expandedMinimumWidth = -1
      policy.sidebarWidth = .infinity
      policy.validate()
      #expect(
        policy.compactMaximumWidth == 600 && policy.expandedMinimumWidth == 600
          && policy.sidebarWidth == 240)
    }
  }

  @Test(
    "Dismissal policies keep browsing open, activation closes, and the backdrop does not activate page content"
  )
  func dismissal() throws {
    try scene { harness, graph, context, input, _ in
      harness.width = 390
      harness.open = true
      harness.closesOnBackdrop = false
      harness.closesOnEscape = false
      harness.closesOnSelection = false
      settle(graph, harness)
      let outside = MouseButtonEvent(button: .left, x: 370, y: 200, clicks: 1)
      input.dispatch(.mouseButtonDown(outside))
      input.dispatch(.mouseButtonUp(outside))
      key(Scancode.escape, input)
      settle(graph, harness)
      #expect(harness.open)
      context.focusChain.focus(try named("sidebar-item-29", graph))
      key(Scancode.return, input)
      settle(graph, harness)
      #expect(harness.open)
      harness.closesOnSelection = true
      settle(graph, harness)
      key(Scancode.return, input)
      settle(graph, harness)
      #expect(!harness.open)
      harness.open = true
      harness.closesOnBackdrop = true
      settle(graph, harness)
      input.dispatch(.mouseButtonDown(outside))
      input.dispatch(.mouseButtonUp(outside))
      settle(graph, harness)
      #expect(!harness.open && !context.focusChain.hasModalScope)
    }
  }

  @Test(
    "Exit and reversal retain nodes, a resize settles the panel, and unmount clears modal input and capture"
  )
  func animationAndLifecycle() throws {
    try scene { harness, graph, context, input, scheduler in
      harness.width = 390
      harness.reduced = false
      settle(graph, harness)
      scheduler.tick(deltaTime: 1)
      settle(graph, harness)
      harness.open = true
      settle(graph, harness)
      let panel = try navigation(graph)
      let row = try named("sidebar-item-29", graph)
      #expect(panel.absoluteFrame.maxX <= 0.5)
      scheduler.tick(deltaTime: 1)
      settle(graph, harness)
      #expect(panel.absoluteFrame.minX == 0)
      harness.open = false
      settle(graph, harness)
      #expect(!row.acceptsSubtreeInput)
      scheduler.tick(deltaTime: 0.05)
      settle(graph, harness)
      let leavingX = panel.absoluteFrame.minX
      #expect(leavingX < 0 && leavingX > -320)
      harness.open = true
      settle(graph, harness)
      #expect(abs(panel.absoluteFrame.minX - leavingX) < 0.5)
      harness.width = 1280
      settle(graph, harness)
      #expect(panel.absoluteFrame.minX == 0 && !context.focusChain.hasModalScope)
      #expect(row.id == (try named("sidebar-item-29", graph)).id)
      harness.width = 390
      settle(graph, harness)
      scheduler.tick(deltaTime: 1)
      settle(graph, harness)
      let close = try #require(
        nodes(graph.tree.root).first {
          $0.accessibility?.label == "Close navigation" && $0.isFocusable
        })
      let frame = close.absoluteFrame
      input.dispatch(
        .mouseButtonDown(
          .init(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)))
      #expect(context.pointerCapture.target != nil)
      graph.install(root: EmptyView())
      graph.recomposer.commitAll()
      #expect(!context.focusChain.hasModalScope && context.pointerCapture.target == nil)
    }
  }

  @Test(
    "Validated AI tools see only available navigation and exclude the modal's blocked page between host frames"
  )
  func aiDiscovery() async throws {
    let prepared = GlobalTestLock.locked {
      let previous = TextEnvironmentHolder.current
      TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
      defer { TextEnvironmentHolder.current = previous }
      let context = PlatformInputContext()
      let scheduler = AnimatorScheduler()
      let portals = PortalStore()
      context.addScopedAmbient(PortalStoreAmbient(portals))
      return context.withCurrent {
        AnimatorScheduler.$current.withValue(scheduler) {
          let harness = Harness()
          harness.width = 390
          harness.open = true
          let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
          graph.install(root: harness)
          settle(graph, harness)
          return (harness, graph, context, scheduler)
        }
      }
    }
    let (harness, graph, context, scheduler) = prepared
    defer {
      GlobalTestLock.locked {
        context.withCurrent {
          graph.install(root: EmptyView())
          scheduler.reset()
        }
      }
    }
    let diagnostics = UIDiagnostics(tree: graph.tree, state: graph.stateRegistry)
    let toolbox = try diagnostics.toolbox()
    for (text, role, expected) in [
      ("Workspace", "dialog", 1), ("Destination 29", "button", 1), ("Background", "button", 0),
    ] {
      let input = try JSONSerialization.data(withJSONObject: [
        "text": text, "role": role, "visible_only": true, "input_enabled_only": true,
      ])
      let result = try await toolbox.execute(name: "query_ui_nodes", input: input)
      let response = try #require(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
      let data = try #require(response["data"] as? [String: Any])
      #expect(data["total"] as? Int == expected)
      #expect(!String(decoding: result.json, as: UTF8.self).contains("Local draft"))
    }
    GlobalTestLock.locked {
      context.withCurrent {
        harness.open = false
        settle(graph, harness)
      }
    }
    let input = Data(
      #"{"text":"Destination 29","visible_only":true,"input_enabled_only":true}"#.utf8)
    let result = try await toolbox.execute(name: "query_ui_nodes", input: input)
    let response = try #require(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
    let data = try #require(response["data"] as? [String: Any])
    #expect(data["total"] as? Int == 0)
  }
}
