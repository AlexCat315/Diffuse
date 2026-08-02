#if canImport(CoreGraphics)
import CoreGraphics
#endif
import GuavaUICompose
import GuavaUIRuntime

private enum _WorkspaceMetrics {
    static let railThickness: Float = 40
}

private struct _WorkspaceRailSlot {
    var id: WorkspaceSlotID
    var edge: WorkspaceEdge
    var thickness: Float
}

private struct _WorkspaceRailPlan {
    var slot: _WorkspaceRailSlot
    var groups: [WorkspaceTabGroup]
}

public struct WorkspaceView: View {
    public let controller: WorkspaceController
    public let content: (WorkspacePanelID) -> AnyView

    @State private var version: UInt64 = 0
    @State private var subscriptionIdentity = WorkspaceSubscriptionIdentity()

    public init(controller: WorkspaceController,
                content: @escaping (WorkspacePanelID) -> AnyView) {
        self.controller = controller
        self.content = content
    }

    public var body: some View {
        let _ = version
        let document = controller.document
        let bind = $version
        let _ = WorkspaceControllerSubscription.acquire(controller: controller,
                                                        tag: ObjectIdentifier(subscriptionIdentity),
                                                        bind: bind)
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            _WorkspaceShell(document: document,
                            controller: controller,
                            content: content)
                .flex()
                .frame(minWidth: 0, minHeight: 0)
            _WorkspaceFloatingLayer(document: document,
                                    controller: controller,
                                    content: content)
        }
            .flex()
            .frame(width: .percent(100),
                   height: .percent(100),
                   minWidth: 0,
                   minHeight: 0)
            .layoutRole("workspace")
            .semanticRole("workspace")
            .debugName("workspace")
            .modifier(_WorkspaceDragOverlayModifier())
    }
}

private final class WorkspaceSubscriptionIdentity {}

private struct _WorkspaceDragOverlayModifier: ViewModifier {
    func apply(node: Node) {
        node.updateOverlayDraw(identity: true) { [weak node] list, _ in
            guard let node,
                  let state = node.attachments[_WorkspaceTabDragOverlayState.key] as? _WorkspaceTabDragOverlayState else {
                return
            }
            drawWorkspaceTabDragOverlay(state: state, in: node, list: list)
        }
    }
}

private struct _WorkspaceTabDragOverlayState: Equatable {
    static let key = "__workspace_tab_drag_overlay"

    var cursorX: Float
    var cursorY: Float
    var title: String
    var resolution: _WorkspaceDragResolution?
}

private enum _WorkspaceDragResolution: Equatable {
    case noop
    case reorder(_WorkspaceReorderPreview)
    case drop(_WorkspaceDropPreview)
}

private struct _WorkspaceReorderPreview: Equatable {
    var groupID: WorkspaceTabGroupID
    var targetIndex: Int
    var lineFrame: CGRect
}

private struct _WorkspaceDropPreview: Equatable {
    var target: WorkspaceTarget
    var frame: CGRect
}

private enum WorkspaceControllerSubscription {
    struct Key: Hashable {
        var controller: ObjectIdentifier
        var tag: ObjectIdentifier
    }

    nonisolated(unsafe) private static var tokens: [Key: WorkspaceController.SubscriptionToken] = [:]

    static func acquire(controller: WorkspaceController,
                        tag: ObjectIdentifier,
                        bind: Binding<UInt64>) -> WorkspaceController.SubscriptionToken {
        let key = Key(controller: ObjectIdentifier(controller), tag: tag)
        if let existing = tokens[key] {
            controller.unsubscribe(existing)
        }
        let token = controller.subscribe { workspace in
            if bind.wrappedValue != workspace.version {
                bind.wrappedValue = workspace.version
            }
        }
        tokens[key] = token
        return token
    }
}

private struct _WorkspaceShell: View {
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        let topVisible = !visibleGroups(in: .top, document: document).isEmpty
        let topCollapsed = !collapsedGroups(in: .top, document: document).isEmpty
        let topChrome = chromeRailSlots(edge: .top, document: document)
        let bottomChrome = visibleChromeRailSlots(edge: .bottom, document: document)
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            topChrome.map { slot in
                AnyView(_WorkspaceChromeSlot(slot: slot, document: document, controller: controller)
                    .id("workspace-chrome-\(slot.id.rawValue)"))
            }
            if topVisible || topCollapsed {
                _WorkspaceEdgeSlot(slotID: .top,
                                   document: document,
                                   controller: controller,
                                   content: content)
                    .id("workspace-slot-top")
            }
            _WorkspaceMainRow(document: document,
                              controller: controller,
                              content: content)
                .flex()
                .frame(minWidth: 0, minHeight: 0)
            bottomChrome.map { slot in
                AnyView(_WorkspaceChromeSlot(slot: slot, document: document, controller: controller)
                    .id("workspace-chrome-\(slot.id.rawValue)"))
            }
        }
        .background(.background)
        .flex()
        .frame(minWidth: 0, minHeight: 0)
    }
}

private struct _WorkspaceMainRow: View {
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        let leadingVisible = !visibleGroups(in: .leading, document: document).isEmpty
        let leadingRail = railPlan(edge: .leading, document: document)
        let trailingVisible = !visibleGroups(in: .trailing, document: document).isEmpty
        let trailingRail = railPlan(edge: .trailing, document: document)
        let weights = WorkspaceShellWeights(document: document,
                                            leadingVisible: leadingVisible,
                                            trailingVisible: trailingVisible)
        Box(direction: .row, alignItems: .stretch, spacing: 0) {
            if let leadingRail {
                _WorkspaceRail(slotID: leadingRail.slot.id,
                               edgeOverride: leadingRail.slot.edge,
                               thickness: leadingRail.slot.thickness,
                               groupsOverride: leadingRail.groups,
                               document: document,
                               controller: controller)
                    .id("workspace-rail-leading")
            }
            if leadingVisible {
                _WorkspaceSideRegion(slotID: .leading,
                                     document: document,
                                     controller: controller,
                                     content: content)
                    .id("workspace-region-leading")
                    .flex(weights.leading, shrink: 1, basis: 0)
                    .frame(minWidth: 0, minHeight: 0)
                _WorkspaceSplitDivider(splitID: "leading",
                                       axis: .vertical,
                                       controller: controller)
                    .debugName("workspace-split-leading")
                    .id("workspace-split-leading")
            }
            _WorkspaceCenterColumn(document: document,
                                   controller: controller,
                                   content: content)
                .debugName("workspace-center-column")
                .id("workspace-center-column")
                .flex(weights.center, shrink: 1, basis: 0)
                .frame(minWidth: 0, minHeight: 0)
            if trailingVisible {
                _WorkspaceSplitDivider(splitID: "centerTrailing",
                                       axis: .vertical,
                                       controller: controller)
                    .debugName("workspace-split-centerTrailing")
                    .id("workspace-split-centerTrailing")
                _WorkspaceSideRegion(slotID: .trailing,
                                     document: document,
                                     controller: controller,
                                     content: content)
                    .id("workspace-region-trailing")
                    .flex(weights.trailing, shrink: 1, basis: 0)
                    .frame(minWidth: 0, minHeight: 0)
            }
            if let trailingRail {
                _WorkspaceRail(slotID: trailingRail.slot.id,
                               edgeOverride: trailingRail.slot.edge,
                               thickness: trailingRail.slot.thickness,
                               groupsOverride: trailingRail.groups,
                               document: document,
                               controller: controller)
                    .id("workspace-rail-trailing")
            }
        }
        .background(.background)
        .flex()
        .frame(minWidth: 0, minHeight: 0)
    }
}

private struct WorkspaceShellWeights {
    var leading: Float
    var center: Float
    var trailing: Float

    init(document: WorkspaceDocument,
         leadingVisible: Bool,
         trailingVisible: Bool) {
        leading = leadingVisible ? document.splitFractions.leading : 0
        let remaining = max(0.05, 1 - leading)
        if trailingVisible {
            center = remaining * document.splitFractions.centerTrailing
            trailing = remaining * (1 - document.splitFractions.centerTrailing)
        } else {
            center = remaining
            trailing = 0
        }
    }
}

private struct _WorkspaceFloatingLayer: View {
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        let windows = document.floatingWindows.sorted { lhs, rhs in
            if lhs.zIndex == rhs.zIndex { return lhs.id.rawValue < rhs.id.rawValue }
            return lhs.zIndex < rhs.zIndex
        }.compactMap { window -> AnyView? in
            guard let group = document.groups[window.groupID] else { return nil }
            return AnyView(_WorkspaceFloatingWindowView(window: window,
                                                        group: group,
                                                        document: document,
                                                        controller: controller,
                                                        content: content)
                .id("workspace-floating-\(window.id.rawValue)"))
        }
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            windows
        }
        .absolutePosition(left: 0, top: 0, right: 0, bottom: 0)
        .zIndex(10_000)
        .layoutRole("workspace-floating-layer")
        .debugName("workspace-floating-layer")
    }
}

private struct _WorkspaceFloatingWindowView: View {
    let window: WorkspaceFloatingWindow
    let group: WorkspaceTabGroup
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Row(alignment: .center, spacing: 6) {
                _WorkspaceFloatingDragHandle(window: window,
                                             controller: controller)
                    .semanticRole("workspace.floating.drag")
                    .debugName("workspace-floating-drag-\(window.id.rawValue)")
                    .flex()
                Button(icon: .resource(WorkspaceIcons.expandDown),
                           size: 11,
                           tooltip: "Attach") {
                    _ = controller.dispatch(.redockFloatingWindow(window.id,
                                                                  to: WorkspaceTarget(slot: .center,
                                                                                      groupID: "center",
                                                                                      placement: .tabGroup)))
                }
                .buttonStyle(.ghost)
                .frame(width: 24, height: 24)
                .semanticRole("workspace.floating.redock")
                .debugName("workspace-floating-redock-\(window.id.rawValue)")
            }
            .padding(horizontal: 6, vertical: 3)
            .background(.surfaceRaised)
            .frame(height: 30)

            _WorkspaceTabGroupView(group: group,
                                   document: document,
                                   controller: controller,
                                   content: content)
                .flex()
        }
        .background(.surface)
        .border(.border, width: 1)
        .cornerRadius(6)
        .shadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x96),
                offsetY: 12,
                blur: 32)
        .frame(width: window.frame.width, height: window.frame.height)
        .absolutePosition(left: window.frame.x, top: window.frame.y)
        .zIndex(Float(window.zIndex))
        .modifier(_WorkspaceFloatingWindowDragModifier(window: window,
                                                       controller: controller))
        .layoutRole("workspace-floating-window")
        .semanticRole("workspace.floating.window")
        .debugName("workspace-floating-window-\(window.id.rawValue)")
    }
}

private struct _WorkspaceFloatingWindowDragModifier: ViewModifier {
    let window: WorkspaceFloatingWindow
    let controller: WorkspaceController

    func apply(node: Node) {
        node.isHitTestable = true
        guard let registry = InteractionRegistryHolder.current else { return }
        let window = window
        let controller = controller
        let route = InputHandlerRoute(role: .workspace,
                                      priority: .capture,
                                      debugName: "workspace.floating.window.drag")
        registry.setPointer(node, route: route) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                let point = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
                if let redockButton = firstNode(rootedAt: node,
                                                debugName: "workspace-floating-redock-\(window.id.rawValue)"),
                   absoluteFrame(of: redockButton).contains(point) {
                    node.attachments[Self.redockKey] = true
                    PointerCaptureHolder.current?.acquire(node)
                    return .handled
                }
                let windowFrame = absoluteFrame(of: node)
                let titleBarFrame = CGRect(x: windowFrame.minX,
                                           y: windowFrame.minY,
                                           width: windowFrame.width,
                                           height: 30)
                guard titleBarFrame.contains(point) else {
                    return .ignored
                }
                node.attachments[Self.dragKey] = _WorkspaceFloatingDragState(startX: event.x,
                                                                              startY: event.y,
                                                                              frame: window.frame)
                PointerCaptureHolder.current?.acquire(node)
                return .handled
            case .up:
                if node.attachments[Self.redockKey] != nil {
                    node.attachments.removeValue(forKey: Self.redockKey)
                    if PointerCaptureHolder.current?.target === node {
                        PointerCaptureHolder.current?.release()
                    }
                    _ = controller.dispatch(.redockFloatingWindow(window.id,
                                                                  to: WorkspaceTarget(slot: .center,
                                                                                      groupID: "center",
                                                                                      placement: .tabGroup)))
                    return .handled
                }
                node.attachments.removeValue(forKey: Self.dragKey)
                if PointerCaptureHolder.current?.target === node {
                    PointerCaptureHolder.current?.release()
                }
                return .handled
            }
        }
        registry.setMotion(node, route: route) { event, _ in
            guard PointerCaptureHolder.current?.target === node,
                  let state = node.attachments[Self.dragKey] as? _WorkspaceFloatingDragState else {
                return .ignored
            }
            let next = WorkspaceRect(x: state.frame.x + event.x - state.startX,
                                     y: state.frame.y + event.y - state.startY,
                                     width: state.frame.width,
                                     height: state.frame.height)
            _ = controller.dispatch(.moveFloatingWindow(window.id, frame: next))
            return .handled
        }
    }

    func apply(layout: LayoutNode) {}

    static let dragKey = "__workspace_floating_window_drag"
    static let redockKey = "__workspace_floating_window_redock"
}

private struct _WorkspaceFloatingDragHandle: _PrimitiveView {
    let window: WorkspaceFloatingWindow
    let controller: WorkspaceController

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {
        node.cursor = .move
        InteractionRegistryHolder.current?.remove(node)
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexGrow = 1
        layout.alignItems = .center
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.flexGrow = 1
        layout.alignItems = .center
    }

    func _children(for node: Node) -> [any View] {
        [Text(window.title)
            .font(SemanticFontRef.label)
            .foregroundColor(.onSurface)]
    }
}

private final class _WorkspaceFloatingDragState {
    let startX: Float
    let startY: Float
    let frame: WorkspaceRect

    init(startX: Float,
         startY: Float,
         frame: WorkspaceRect) {
        self.startX = startX
        self.startY = startY
        self.frame = frame
    }
}

private struct _WorkspaceCenterColumn: View {
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        let bottomVisible = !visibleGroups(in: .bottom, document: document).isEmpty
        let bottomRail = bottomVisible ? nil : railPlan(edge: .bottom, document: document)
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            _WorkspaceSlotView(slotID: .center,
                                 document: document,
                                 controller: controller,
                                 content: content)
                .flex(bottomVisible ? document.splitFractions.topBottom : 1,
                      shrink: 1,
                      basis: 0)
                .frame(minWidth: 0, minHeight: 0)
            if bottomVisible {
                _WorkspaceSplitDivider(splitID: "topBottom",
                                       axis: .horizontal,
                                       controller: controller)
                    .debugName("workspace-split-topBottom")
                    .id("workspace-split-topBottom")
                _WorkspaceBottomSlot(document: document,
                                     controller: controller,
                                     content: content)
                        .flex(1 - document.splitFractions.topBottom,
                              shrink: 1,
                              basis: 0)
                        .frame(minWidth: 0, minHeight: 0)
            } else if let bottomRail {
                Divider()
                _WorkspaceChromeSlot(slot: bottomRail.slot,
                                     groupsOverride: bottomRail.groups,
                                     document: document,
                                     controller: controller)
                    .id("workspace-chrome-\(bottomRail.slot.id.rawValue)")
            }
        }
        .flex()
        .frame(minWidth: 0, minHeight: 0)
    }
}

private struct _WorkspaceSideRegion: View {
    let slotID: WorkspaceSlotID
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        _WorkspaceSlotView(slotID: slotID,
                             document: document,
                             controller: controller,
                             content: content)
    }
}

private struct _WorkspaceEdgeSlot: View {
    let slotID: WorkspaceSlotID
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        let visible = !visibleGroups(in: slotID, document: document).isEmpty
        let collapsed = !collapsedGroups(in: slotID, document: document).isEmpty
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if visible {
                _WorkspaceSlotView(slotID: slotID,
                                   document: document,
                                   controller: controller,
                                   content: content)
                    .id("workspace-region-\(slotID.rawValue)")
                    .frame(height: 160)
            }
            if collapsed {
                _WorkspaceRail(slotID: slotID,
                               document: document,
                               controller: controller)
                    .id("workspace-rail-\(slotID.rawValue)")
            }
        }
        .layoutRole("workspace-edge-slot")
        .debugName("workspace-slot-\(slotID.rawValue)")
    }
}

private struct _WorkspaceRailReserve: View {
    let slot: _WorkspaceRailSlot

    var body: some View {
        let horizontal = slot.edge == .top || slot.edge == .bottom
        Box { EmptyView() }
            .frame(width: horizontal ? nil : slot.thickness,
                   height: horizontal ? slot.thickness : nil)
            .layoutRole("workspace-rail-reserve")
            .semanticRole("workspace.rail.reserve.\(slot.edge.rawValue)")
            .debugName("workspace-rail-reserve-\(slot.edge.rawValue)")
    }
}

private struct _WorkspaceChromeSlot: View {
    let slot: _WorkspaceRailSlot
    var groupsOverride: [WorkspaceTabGroup]? = nil
    let document: WorkspaceDocument
    let controller: WorkspaceController

    var body: some View {
        let horizontal = slot.edge == .top || slot.edge == .bottom
        Box(direction: horizontal ? .row : .column,
            alignItems: .stretch,
            spacing: 0) {
            _WorkspaceRail(slotID: slot.id,
                           edgeOverride: slot.edge,
                           thickness: slot.thickness,
                           groupsOverride: groupsOverride,
                           document: document,
                           controller: controller)
                .id("workspace-rail-\(slot.id.rawValue)")
        }
        .background(.background)
        .frame(width: horizontal ? nil : slot.thickness,
               height: horizontal ? slot.thickness : nil)
        .layoutRole("workspace-chrome-slot")
        .semanticRole("workspace.chrome.\(slot.id.rawValue)")
        .debugName("workspace-chrome-\(slot.id.rawValue)")
    }
}

private struct _WorkspaceBottomSlot: View {
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        let visible = visibleGroups(in: .bottom, document: document)
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if !visible.isEmpty {
                _WorkspaceSlotView(slotID: .bottom,
                                     document: document,
                                     controller: controller,
                                     content: content)
                    .id("workspace-region-bottom")
                    .flex()
                    .frame(minWidth: 0, minHeight: 0)
            }
        }
        .layoutRole("workspace-bottom-slot")
        .debugName("workspace-bottom-slot")
    }
}

private struct _WorkspaceSlotView: View {
    let slotID: WorkspaceSlotID
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if let layout = renderableLayout(in: slotID, document: document) {
                _WorkspaceLayoutNodeView(node: layout,
                                         document: document,
                                         controller: controller,
                                         content: content)
                    .flex()
                    .frame(minWidth: 0, minHeight: 0)
            } else {
                EmptyView()
                    .flex()
            }
        }
        .frame(minWidth: 0, minHeight: 0)
        .layoutRole("workspace-region")
        .semanticRole("workspace.slot.\(slotID.rawValue)")
        .debugName("workspace-region-\(slotID.rawValue)")
    }
}

private struct _WorkspaceLayoutNodeView: View {
    let node: WorkspaceLayoutNode
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        switch node {
        case .group(let groupID):
            if let group = document.groups[groupID] {
                _WorkspaceTabGroupView(group: group,
                                       document: document,
                                       controller: controller,
                                       content: content)
                    .id(group.id)
                    .flex()
                    .frame(minWidth: 0, minHeight: 0)
            } else {
                EmptyView()
                    .flex()
            }
        case .split(let axis, let fraction, let first, let second):
            Box(direction: axis == .horizontal ? .row : .column,
                alignItems: .stretch,
                spacing: 8) {
                _WorkspaceLayoutNodeView(node: first,
                                         document: document,
                                         controller: controller,
                                         content: content)
                    .flex(fraction, shrink: 1, basis: 0)
                    .frame(minWidth: 0, minHeight: 0)
                _WorkspaceLayoutNodeView(node: second,
                                         document: document,
                                         controller: controller,
                                         content: content)
                    .flex(1 - fraction, shrink: 1, basis: 0)
                    .frame(minWidth: 0, minHeight: 0)
            }
            .frame(minWidth: 0, minHeight: 0)
            .layoutRole("workspace-split")
            .semanticRole("workspace.split.\(axis.rawValue)")
        }
    }
}

private struct _WorkspaceTabGroupView: View {
    let group: WorkspaceTabGroup
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        let activeID = group.activePanelID ?? group.panels.first
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            _WorkspaceTabBar(group: group,
                             document: document,
                             controller: controller)
            if let activeID {
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    content(activeID)
                        .flex()
                        .frame(minWidth: 0, minHeight: 0)
                }
                    .flex()
                    .frame(minWidth: 0, minHeight: 0)
                    .clipped()
                    .semanticRole("workspace.panel.content")
                    .debugName("workspace-panel-\(activeID.rawValue)")
            } else {
                EmptyView()
                    .flex()
            }
        }
        .background(.surfaceSunken)
        .cornerRadius(12)
        .clipped()
        .frame(minWidth: 0, minHeight: 0)
        .layoutRole("workspace-tab-group")
        .semanticRole("workspace.group")
        .debugName("workspace-group-\(group.id.rawValue)")
    }
}

private struct _WorkspaceTabBar: View {
    let group: WorkspaceTabGroup
    let document: WorkspaceDocument
    let controller: WorkspaceController

    var body: some View {
        let slotID = document.slotContaining(groupID: group.id)
        let canCollapse = slotID != nil && slotID != .center && group.panels.contains { panelID in
            document.panels[panelID]?.isCollapsible == true
        }
        let tabButtons = group.panels.compactMap { panelID -> AnyView? in
            guard document.panels[panelID] != nil else { return nil }
            return AnyView(_WorkspaceTabButton(groupID: group.id,
                                               panelID: panelID,
                                               title: document.panels[panelID]!.title,
                                               isActive: panelID == group.activePanelID,
                                               isPinned: group.isPinned(panelID),
                                               document: document,
                                               controller: controller)
                .semanticRole("workspace.tab")
                .debugName("workspace-tab-\(panelID.rawValue)"))
        }
        Row(alignment: .center, spacing: 0) {
            tabButtons
            Spacer(minLength: 0)
            if canCollapse {
                Button(icon: .resource(WorkspaceIcons.collapse(for: slotID)),
                           size: 12,
                           tooltip: "Collapse") {
                    _ = controller.dispatch(.collapse(group.id))
                }
                .buttonStyle(.ghost)
                .frame(width: 24, height: 24)
                .semanticRole("workspace.group.collapse")
                .debugName("workspace-collapse-\(group.id.rawValue)")
            }
        }
        .padding(horizontal: 4, vertical: 3)
        .background(.surfaceSunken)
        .frame(height: 30)
        .layoutRole("workspace-tab-bar")
    }
}

private struct _WorkspaceTabButton: View {
    let groupID: WorkspaceTabGroupID
    let panelID: WorkspacePanelID
    let title: String
    let isActive: Bool
    let isPinned: Bool
    let document: WorkspaceDocument
    let controller: WorkspaceController

    @State private var isPressed = false
    @State private var isHovered = false

    var body: some View {
        _WorkspaceTabButtonHost(groupID: groupID,
                                panelID: panelID,
                                title: title,
                                isActive: isActive,
                                isPinned: isPinned,
                                isPressed: isPressed,
                                isHovered: isHovered,
                                document: document,
                                controller: controller,
                                onHoverChange: { hovered in
                                    if isHovered != hovered {
                                        isHovered = hovered
                                    }
                                },
                                onDown: {
                                    if !isPressed {
                                        isPressed = true
                                    }
                                },
                                onCancelPress: {
                                    isPressed = false
                                },
                                onClick: {
                                    isPressed = false
                                    _ = controller.dispatch(.setActivePanel(groupID: groupID, panelID: panelID))
                                },
                                onDrop: { target in
                                    isPressed = false
                                    _ = controller.dispatch(.movePanel(panelID, to: target))
                                },
                                onReorder: { groupID, index in
                                    isPressed = false
                                    _ = controller.dispatch(.reorderPanel(panelID, in: groupID, toIndex: index))
                                })
    }
}

private struct _WorkspaceTabButtonHost: _PrimitiveView {
    let groupID: WorkspaceTabGroupID
    let panelID: WorkspacePanelID
    let title: String
    let isActive: Bool
    let isPinned: Bool
    let isPressed: Bool
    let isHovered: Bool
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let onHoverChange: (Bool) -> Void
    let onDown: () -> Void
    let onCancelPress: () -> Void
    let onClick: () -> Void
    let onDrop: (WorkspaceTarget) -> Void
    let onReorder: (WorkspaceTabGroupID, Int) -> Void

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.isFocusable = true
        return node
    }

    func _updateNode(_ node: Node) {
        node.cursor = .pointer
        guard let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node)
            return
        }

        let hoverChange = onHoverChange
        let down = onDown
        let cancelPress = onCancelPress
        let click = onClick
        let drop = onDrop
        let reorder = onReorder
        let document = document
        let groupID = groupID
        let panelID = panelID

        registry.setHover(node) { phase in
            switch phase {
            case .enter:
                hoverChange(true)
            case .leave:
                hoverChange(false)
            }
        }
        let route = InputHandlerRoute(role: .workspace,
                                      priority: .capture,
                                      debugName: "workspace.tab.drag")
        registry.setPointer(node, route: route) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                guard document.panels[panelID]?.isDraggable != false else {
                    return .ignored
                }
                node.attachments[Self.pressKey] = _WorkspaceTabPressState(downX: event.x,
                                                                           downY: event.y,
                                                                           lastX: event.x,
                                                                           lastY: event.y,
                                                                           didDrag: false)
                PointerCaptureHolder.current?.acquire(node)
                down()
                return .handled
            case .up:
                let state = node.attachments[Self.pressKey] as? _WorkspaceTabPressState
                node.attachments.removeValue(forKey: Self.pressKey)
                node.cursor = .pointer
                node.opacity = 1
                if let root = workspaceRoot(from: node) {
                    setWorkspaceTabDragOverlay(nil, on: root)
                }
                if PointerCaptureHolder.current?.target === node {
                    PointerCaptureHolder.current?.release()
                }
                guard let state else { return .ignored }
                if state.didDrag {
                    if let resolution = resolveWorkspaceDragResolution(x: event.x,
                                                                       y: event.y,
                                                                       sourceGroupID: groupID,
                                                                       sourcePanelID: panelID,
                                                                       document: document,
                                                                       from: node) {
                        switch resolution {
                        case .noop:
                            cancelPress()
                        case .reorder(let preview):
                            reorder(preview.groupID, preview.targetIndex)
                        case .drop(let preview):
                            drop(preview.target)
                        }
                    } else {
                        cancelPress()
                    }
                    return .handled
                }
                click()
                return .handled
            }
        }
        registry.setMotion(node, route: route) { event, _ in
            guard PointerCaptureHolder.current?.target === node,
                  let state = node.attachments[Self.pressKey] as? _WorkspaceTabPressState else {
                return .ignored
            }
            let dx = event.x - state.downX
            let dy = event.y - state.downY
            state.lastX = event.x
            state.lastY = event.y
            if !state.didDrag, max(abs(dx), abs(dy)) >= 4 {
                state.didDrag = true
                cancelPress()
                node.cursor = .move
                node.opacity = 0.42
            }
            if state.didDrag,
               let root = workspaceRoot(from: node) {
                let title = document.panels[panelID]?.title ?? panelID.rawValue
                let resolution = resolveWorkspaceDragResolution(x: event.x,
                                                                 y: event.y,
                                                                 sourceGroupID: groupID,
                                                                 sourcePanelID: panelID,
                                                                 document: document,
                                                                 from: node)
                setWorkspaceTabDragOverlay(_WorkspaceTabDragOverlayState(cursorX: event.x,
                                                                          cursorY: event.y,
                                                                          title: title,
                                                                          resolution: resolution),
                                           on: root)
            }
            return state.didDrag ? .handled : .ignored
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .row
        layout.alignItems = .center
        layout.justifyContent = .center
        return layout
    }

    func _children(for node: Node) -> [any View] {
        let style = AnyButtonStyle(_WorkspaceTabButtonStyle())
        // Resolve the title color eagerly from this (parented) host node's theme
        // and pass it to `Text` directly. The button style's deferred
        // `.foregroundColor(.onSurface)` resolves against the *label* node's
        // theme at apply-time, and that label — built deep inside this
        // primitive's `_children` — isn't parented under the theme provider yet,
        // so it falls back to `.defaultDark` and bakes near-white tab titles in
        // light mode. `node.theme` here is correct (it already drives the tab bg).
        let titleColor = node.theme.colors.onSurface
        let config = ButtonStyleConfiguration(label: AnyView(Row(alignment: .center, spacing: 4) {
                                                  if isPinned {
                                                      Icon(WorkspaceIcons.pinDot, size: 6, color: titleColor)
                                                  }
                                                  Text(title, color: titleColor).font(.label)
                                              }),
                                              role: .normal,
                                              isPressed: isPressed,
                                              isHovered: isHovered,
                                              isFocused: FocusChainHolder.current?.focused === node,
                                              isEnabled: true,
                                              isSelected: isActive,
                                              theme: node.theme)
        return [style.makeBody(config)]
    }

    static let pressKey = "__workspace_tab_press"
}

/// Tab look as one style keyed off `configuration.isSelected` (raised
/// secondary chrome when active, ghost otherwise) instead of swapping whole
/// styles around the state.
private struct _WorkspaceTabButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        if configuration.isSelected {
            AnyView(SecondaryButtonStyle().makeBody(configuration: configuration))
        } else {
            AnyView(GhostButtonStyle().makeBody(configuration: configuration))
        }
    }
}

private final class _WorkspaceTabPressState {
    let downX: Float
    let downY: Float
    var lastX: Float
    var lastY: Float
    var didDrag: Bool

    init(downX: Float, downY: Float, lastX: Float, lastY: Float, didDrag: Bool) {
        self.downX = downX
        self.downY = downY
        self.lastX = lastX
        self.lastY = lastY
        self.didDrag = didDrag
    }
}

private func setWorkspaceTabDragOverlay(_ state: _WorkspaceTabDragOverlayState?,
                                        on root: Node) {
    let previous = root.attachments[_WorkspaceTabDragOverlayState.key] as? _WorkspaceTabDragOverlayState
    guard previous != state else { return }
    if let state {
        root.attachments[_WorkspaceTabDragOverlayState.key] = state
    } else {
        root.attachments.removeValue(forKey: _WorkspaceTabDragOverlayState.key)
    }
    root.markRenderDirty(reason: .styleSet(field: "workspaceTabDragOverlay"))
}

private func drawWorkspaceTabDragOverlay(state: _WorkspaceTabDragOverlayState,
                                         in root: Node,
                                         list: DrawList) {
    switch state.resolution {
    case .noop:
        break
    case .reorder(let preview):
        drawWorkspaceReorderPreview(preview, theme: root.theme, list: list)
    case .drop(let preview):
        drawWorkspaceDropPreview(preview, theme: root.theme, list: list)
    case nil:
        break
    }
    drawWorkspaceDragGhost(state: state, in: root, list: list)
}

private func drawWorkspaceDropPreview(_ preview: _WorkspaceDropPreview,
                                      theme: Theme,
                                      list: DrawList) {
    let inset: Float = preview.target.placement == .slot ? 5 : 3
    let rect = insetWorkspaceRect(workspaceUIRect(preview.frame), by: inset)
    guard rect.width > 2, rect.height > 2 else { return }
    let accent = theme.colors.accent
    let fillAlpha: Float = preview.target.placement == .tabGroup ? 0.10 : 0.16
    list.addRoundedRect(rect, radius: 7, color: accent.multipliedAlpha(fillAlpha))
    addWorkspaceRectBorder(rect: rect,
                           color: accent.multipliedAlpha(0.92),
                           thickness: 2,
                           list: list)

    guard preview.target.placement == .split,
          let edge = preview.target.edge else {
        return
    }
    let barThickness: Float = 5
    let bar: UIRect
    switch edge {
    case .leading:
        bar = UIRect(x: rect.minX, y: rect.minY, width: barThickness, height: rect.height)
    case .trailing:
        bar = UIRect(x: rect.maxX - barThickness, y: rect.minY, width: barThickness, height: rect.height)
    case .top:
        bar = UIRect(x: rect.minX, y: rect.minY, width: rect.width, height: barThickness)
    case .bottom:
        bar = UIRect(x: rect.minX, y: rect.maxY - barThickness, width: rect.width, height: barThickness)
    }
    list.addRoundedRect(bar, radius: 2.5, color: accent.multipliedAlpha(0.98))
}

private func drawWorkspaceReorderPreview(_ preview: _WorkspaceReorderPreview,
                                         theme: Theme,
                                         list: DrawList) {
    let rect = workspaceUIRect(preview.lineFrame)
    guard rect.width > 0, rect.height > 0 else { return }
    let accent = theme.colors.accent
    list.addRoundedRect(rect, radius: 1.5, color: accent.multipliedAlpha(0.98))
    list.addRoundedRect(UIRect(x: rect.minX - 3,
                               y: rect.minY,
                               width: rect.width + 6,
                               height: 3),
                        radius: 1.5,
                        color: accent)
    list.addRoundedRect(UIRect(x: rect.minX - 3,
                               y: rect.maxY - 3,
                               width: rect.width + 6,
                               height: 3),
                        radius: 1.5,
                        color: accent)
}

private func drawWorkspaceDragGhost(state: _WorkspaceTabDragOverlayState,
                                    in root: Node,
                                    list: DrawList) {
    let title = cleanedWorkspaceDragTitle(state.title)
    let font = Font.system(size: 12, weight: .medium)
    var textLayout: TextLayoutResult?
    var textWidth = min(170, max(42, Float(title.count) * 7))
    if let env = TextEnvironmentHolder.current {
        let layout = env.cachedLayout(text: title,
                                      font: font,
                                      lineHeight: 16,
                                      maxWidth: 170,
                                      alignment: .leading)
        textLayout = layout
        textWidth = min(170, max(42, layout.totalWidth))
    }

    let width = min(220, max(112, textWidth + 34))
    let height: Float = 28
    let bounds = absoluteFrame(of: root)
    let minX = Float(bounds.minX) + 6
    let minY = Float(bounds.minY) + 6
    let maxX = max(minX, Float(bounds.maxX) - width - 6)
    let maxY = max(minY, Float(bounds.maxY) - height - 6)
    let x = min(max(state.cursorX + 14, minX), maxX)
    let y = min(max(state.cursorY + 10, minY), maxY)
    let rect = UIRect(x: x, y: y, width: width, height: height)
    let colors = root.theme.colors

    list.addRoundedRect(rect,
                        radius: 6,
                        color: colors.surfaceFloating.multipliedAlpha(0.96))
    addWorkspaceRectBorder(rect: rect,
                           color: colors.accent.multipliedAlpha(0.55),
                           thickness: 1,
                           list: list)
    list.addRoundedRect(UIRect(x: rect.minX + 7,
                               y: rect.minY + 6,
                               width: 3,
                               height: rect.height - 12),
                        radius: 1.5,
                        color: colors.accent.multipliedAlpha(0.95))

    guard let textLayout,
          let env = TextEnvironmentHolder.current else {
        return
    }
    let textY = rect.minY + max(0, (rect.height - textLayout.totalHeight) * 0.5)
    list.addText(textLayout,
                 origin: (rect.minX + 20, textY),
                 color: colors.onSurface,
                 textureID: env.atlasTextureID,
                 atlas: env.atlas)
}

private func cleanedWorkspaceDragTitle(_ title: String) -> String {
    let clean = title
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? "Panel" : clean
}

private func workspaceUIRect(_ rect: CGRect) -> UIRect {
    UIRect(x: Float(rect.minX),
           y: Float(rect.minY),
           width: Float(rect.width),
           height: Float(rect.height))
}

private func insetWorkspaceRect(_ rect: UIRect, by amount: Float) -> UIRect {
    UIRect(x: rect.x + amount,
           y: rect.y + amount,
           width: max(0, rect.width - amount * 2),
           height: max(0, rect.height - amount * 2))
}

private func addWorkspaceRectBorder(rect: UIRect,
                                    color: Color,
                                    thickness: Float,
                                    list: DrawList) {
    let t = max(1, thickness)
    list.addRect(UIRect(x: rect.minX, y: rect.minY, width: rect.width, height: t), color: color)
    list.addRect(UIRect(x: rect.minX, y: rect.maxY - t, width: rect.width, height: t), color: color)
    list.addRect(UIRect(x: rect.minX, y: rect.minY, width: t, height: rect.height), color: color)
    list.addRect(UIRect(x: rect.maxX - t, y: rect.minY, width: t, height: rect.height), color: color)
}

private enum _WorkspaceSplitAxis {
    case vertical
    case horizontal
}

private struct _WorkspaceSplitDivider: _PrimitiveView {
    let splitID: WorkspaceSplitID
    let axis: _WorkspaceSplitAxis
    let controller: WorkspaceController

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        return node
    }

    func _updateNode(_ node: Node) {
        let theme = resolveWorkspaceTheme(on: node)
        let hitSize = max(1, theme.splitDividerThickness + theme.splitDividerHitSlop * 2)
        node.cursor = axis == .vertical ? .resizeHorizontal : .resizeVertical
        node.animatableSet(\.backgroundColor, to: nil)
        switch axis {
        case .vertical:
            node.layoutNode?.width = hitSize
        case .horizontal:
            node.layoutNode?.height = hitSize
        }

        let controller = controller
        let splitID = splitID
        let axis = axis
        guard let registry = InteractionRegistryHolder.current else { return }
        let route = InputHandlerRoute(role: .workspace,
                                      priority: .capture,
                                      debugName: "workspace.split")
        registry.setPointer(node, route: route) { _, phase, _ in
            switch phase {
            case .down:
                PointerCaptureHolder.current?.acquire(node)
                return .handled
            case .up:
                if PointerCaptureHolder.current?.target === node {
                    PointerCaptureHolder.current?.release()
                }
                return .handled
            }
        }
        registry.setMotion(node, route: route) { event, _ in
            guard PointerCaptureHolder.current?.target === node,
                  let fraction = resolveWorkspaceSplitFraction(splitID: splitID,
                                                               axis: axis,
                                                               x: event.x,
                                                               y: event.y,
                                                               from: node) else {
                return .ignored
            }
            _ = controller.dispatch(.resizeSplit(splitID, fraction: fraction))
            return .handled
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        switch axis {
        case .vertical:
            layout.flexDirection = .row
            layout.alignItems = .stretch
            layout.justifyContent = .center
            layout.width = 1
        case .horizontal:
            layout.flexDirection = .column
            layout.alignItems = .stretch
            layout.justifyContent = .center
            layout.height = 1
        }
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        switch axis {
        case .vertical:
            layout.flexDirection = .row
            layout.alignItems = .stretch
            layout.justifyContent = .center
            if (layout.width ?? 0) <= 0 { layout.width = 1 }
        case .horizontal:
            layout.flexDirection = .column
            layout.alignItems = .stretch
            layout.justifyContent = .center
            if (layout.height ?? 0) <= 0 { layout.height = 1 }
        }
    }

    func _children(for node: Node) -> [any View] {
        [_WorkspaceSplitDividerLine(axis: axis)]
    }
}

private struct _WorkspaceSplitDividerLine: _PrimitiveView {
    let axis: _WorkspaceSplitAxis

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {
        let theme = resolveWorkspaceTheme(on: node)
        // Floating-island chrome: the gutter shows the window canvas; no
        // painted line. The parent divider node keeps the resize hit area.
        node.animatableSet(\.backgroundColor, to: nil)
        let thickness = max(1, theme.splitDividerThickness)
        switch axis {
        case .vertical:
            node.layoutNode?.width = thickness
        case .horizontal:
            node.layoutNode?.height = thickness
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        switch axis {
        case .vertical:
            layout.width = 1
            layout.alignSelf = .stretch
        case .horizontal:
            layout.height = 1
            layout.alignSelf = .stretch
        }
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        switch axis {
        case .vertical:
            layout.alignSelf = .stretch
            if (layout.width ?? 0) <= 0 { layout.width = 1 }
        case .horizontal:
            layout.alignSelf = .stretch
            if (layout.height ?? 0) <= 0 { layout.height = 1 }
        }
    }
}

private struct _WorkspaceRail: View {
    let slotID: WorkspaceSlotID
    var edgeOverride: WorkspaceEdge? = nil
    var thickness: Float = _WorkspaceMetrics.railThickness
    var groupsOverride: [WorkspaceTabGroup]? = nil
    let document: WorkspaceDocument
    let controller: WorkspaceController

    var body: some View {
        let groups = groupsOverride ?? railGroups(in: slotID, edgeOverride: edgeOverride, document: document)
        let edge = edgeOverride ?? railEdge(slotID: slotID, document: document)
        let horizontal = edge == .top || edge == .bottom
        let railButtons = groups.flatMap { group in
            railItems(group: group, document: document).map { item in
                AnyView(_WorkspaceRailButton(slotID: slotID,
                                             isHorizontal: horizontal,
                                             groupID: group.id,
                                             title: item.title,
                                             icon: WorkspacePanelIconCatalog.resolve(item.iconAssetKey),
                                             controller: controller)
                    .id("workspace-restore-\(slotID.rawValue)-\(group.id.rawValue)-\(item.panelID.rawValue)"))
            }
        }
        if groups.isEmpty {
            EmptyView()
        } else if horizontal {
            Row(alignment: .center, spacing: 6) {
                railButtons
            }
            .padding(horizontal: 4, vertical: 4)
            .background(.background)
            .frame(width: .percent(100),
                   height: .points(thickness))
            .layoutRole("workspace-rail")
            .semanticRole("workspace.rail.\(edge.rawValue)")
            .debugName("workspace-rail-\(edge.rawValue)")
        } else {
            Box(direction: .column, alignItems: .center, spacing: 4) {
                railButtons
            }
            .padding(horizontal: 4, vertical: 6)
            .background(.background)
            .frame(width: thickness)
            .layoutRole("workspace-rail")
            .semanticRole("workspace.rail.\(edge.rawValue)")
            .debugName("workspace-rail-\(edge.rawValue)")
        }
    }
}

private struct _WorkspaceRailButton: View {
    let slotID: WorkspaceSlotID
    let isHorizontal: Bool
    let groupID: WorkspaceTabGroupID
    let title: String
    let icon: BundleImageResource?
    let controller: WorkspaceController

    var body: some View {
        // Activity-bar idiom: a collapsed panel is a square icon button whose
        // tooltip carries the title. Text pills are the no-icon fallback only.
        if let icon {
            Button(tooltip: title) {
                _ = controller.dispatch(.expand(groupID))
            } label: {
                Icon(icon, size: 16, color: .white)
                    .padding(horizontal: 6, vertical: 6)
            }
            .buttonStyle(_WorkspaceRailRestoreStyle())
            .semanticRole("workspace.rail.restore")
            .debugName("workspace-restore-\(groupID.rawValue)")
        } else if isHorizontal {
            Button(tooltip: title) {
                _ = controller.dispatch(.expand(groupID))
            } label: {
                Row(alignment: .center, spacing: 6) {
                    Icon(WorkspaceIcons.expandDown, size: 10, color: .white)
                    Text(title)
                        .font(.label)
                }
                .padding(horizontal: 8, vertical: 4)
            }
            .buttonStyle(_WorkspaceRailRestoreStyle())
            .semanticRole("workspace.rail.restore")
            .debugName("workspace-restore-\(groupID.rawValue)")
        } else {
            Button(tooltip: title) {
                _ = controller.dispatch(.expand(groupID))
            } label: {
                _WorkspaceVerticalTitle(title: title)
            }
            .buttonStyle(_WorkspaceRailRestoreStyle())
            .semanticRole("workspace.rail.restore")
            .debugName("workspace-restore-\(groupID.rawValue)")
        }
    }
}

/// Collapsed-panel restore button — the tool-strip idiom shared by every rail
/// orientation: transparent at rest on the canvas, a state-layer wash on
/// hover/press, muted label that brightens on hover, no border.
private struct _WorkspaceRailRestoreStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let clear = Color(r: 0, g: 0, b: 0, a: 0)
        let bg: Color = {
            if !configuration.isEnabled { return clear }
            if configuration.isPressed { return theme.colors.stateLayerPressed }
            if configuration.isHovered { return theme.colors.stateLayerHover }
            return clear
        }()
        let fg: SemanticColorRef = configuration.isHovered ? .onSurface : .onSurfaceMuted

        return Box(direction: .column,
                   alignItems: .center,
                   justifyContent: .center,
                   spacing: 0) {
            AnyView(configuration.label)
                .font(SemanticFontRef.label)
                .foregroundColor(fg)
        }
        .padding(horizontal: 4, vertical: 4)
        .background(bg)
        .cornerRadius(6)
        .border(configuration.isFocused ? theme.colors.focusRing : clear,
                width: configuration.isFocused ? 2 : 0)
        .opacity(configuration.isEnabled ? 1 : 0.55)
        .animation(.semantic(.snappy, in: theme), value: configuration.interactionKey)
    }
}

private struct _WorkspaceVerticalTitle: View {
    let title: String

    var body: some View {
        // Stacking one character per line is idiomatic vertical CJK, but
        // short Latin runs ("AI") read as broken text — keep those横排.
        if isShortLatin {
            Text(cleanTitle)
                .font(Font.system(size: 11, weight: .medium))
                .frame(minHeight: 28)
        } else {
            Box(direction: .column, alignItems: .center, justifyContent: .center, spacing: 1) {
                characters.map { char in
                    AnyView(Text(char)
                        .font(Font.system(size: 11, weight: .medium))
                        .lineHeight(12)
                        .frame(width: 24, height: 12))
                }
            }
            .frame(width: 24, minHeight: max(48, Float(characters.count) * 13 + 12))
        }
    }

    private var cleanTitle: String {
        let clean = title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Panel" : clean
    }

    private var isShortLatin: Bool {
        cleanTitle.count <= 3 && cleanTitle.allSatisfy { $0.isASCII }
    }

    private var characters: [String] {
        cleanTitle.map { String($0) }
    }
}

private struct RailItem {
    var panelID: WorkspacePanelID
    var title: String
    var iconAssetKey: String?
}

private func visibleGroups(in slotID: WorkspaceSlotID,
                           document: WorkspaceDocument) -> [WorkspaceTabGroup] {
    (document.slot(slotID).layout?.leafGroupIDs ?? [])
        .compactMap { document.groups[$0] }
        .filter { !$0.isCollapsed }
}

private func renderableLayout(in slotID: WorkspaceSlotID,
                              document: WorkspaceDocument) -> WorkspaceLayoutNode? {
    compactLayout(document.slot(slotID).layout, document: document)
}

private func compactLayout(_ node: WorkspaceLayoutNode?,
                           document: WorkspaceDocument) -> WorkspaceLayoutNode? {
    guard let node else { return nil }
    switch node {
    case .group(let groupID):
        guard let group = document.groups[groupID],
              !group.isCollapsed,
              !group.panels.isEmpty else {
            return nil
        }
        return .group(groupID)
    case .split(let axis, let fraction, let first, let second):
        let nextFirst = compactLayout(first, document: document)
        let nextSecond = compactLayout(second, document: document)
        switch (nextFirst, nextSecond) {
        case (nil, nil):
            return nil
        case (let remaining?, nil), (nil, let remaining?):
            return remaining
        case (let nextFirst?, let nextSecond?):
            return .split(axis: axis,
                          fraction: fraction,
                          first: nextFirst,
                          second: nextSecond)
        }
    }
}

private func collapsedGroups(in slotID: WorkspaceSlotID,
                             document: WorkspaceDocument) -> [WorkspaceTabGroup] {
    document.collapsed
        .filter { $0.slotID == slotID }
        .compactMap { document.groups[$0.groupID] }
        .filter(\.isCollapsed)
}

private func collapsedGroups(on edge: WorkspaceEdge,
                             document: WorkspaceDocument) -> [WorkspaceTabGroup] {
    document.collapsed
        .filter { $0.edge == edge }
        .compactMap { document.groups[$0.groupID] }
        .filter(\.isCollapsed)
}

private func railGroups(in slotID: WorkspaceSlotID,
                        edgeOverride: WorkspaceEdge? = nil,
                        document: WorkspaceDocument) -> [WorkspaceTabGroup] {
    if let edgeOverride {
        return collapsedGroups(on: edgeOverride, document: document)
    }
    let slot = document.slot(slotID)
    if case .chrome(let edge, _) = slot.kind {
        return collapsedGroups(on: edge, document: document)
    }
    return collapsedGroups(in: slotID, document: document)
}

private func railItems(group: WorkspaceTabGroup,
                       document: WorkspaceDocument) -> [RailItem] {
    group.panels.compactMap { panelID in
        guard let panel = document.panels[panelID] else { return nil }
        return RailItem(panelID: panelID,
                        title: panel.title,
                        iconAssetKey: panel.iconAssetKey)
    }
}

private func railPlan(edge: WorkspaceEdge,
                      document: WorkspaceDocument) -> _WorkspaceRailPlan? {
    let groups = collapsedGroups(on: edge, document: document)
    guard !groups.isEmpty else { return nil }
    let slot = collapsedChromeRailSlot(edge: edge, document: document)
        ?? fallbackChromeRailSlot(edge: edge)
    return _WorkspaceRailPlan(slot: slot, groups: groups)
}

private func chromeRailSlots(edge: WorkspaceEdge,
                             document: WorkspaceDocument) -> [_WorkspaceRailSlot] {
    let collapsedOnEdge = !collapsedGroups(on: edge, document: document).isEmpty
    let slots = document.slots.values
        .filter { slot in
            guard case .chrome(let slotEdge, _) = slot.kind,
                  slotEdge == edge else {
                return false
            }
            return slot.layout != nil || collapsedOnEdge
        }
        .sorted { lhs, rhs in
            let preferred = WorkspaceSlotID.chromeRail(for: edge)
            if lhs.id == preferred { return true }
            if rhs.id == preferred { return false }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        .compactMap(chromeRailSlot)
    if collapsedOnEdge {
        return Array(slots.prefix(1))
    }
    return slots
}

private func visibleChromeRailSlots(edge: WorkspaceEdge,
                                    document: WorkspaceDocument) -> [_WorkspaceRailSlot] {
    document.slots.values
        .filter { slot in
            guard case .chrome(let slotEdge, _) = slot.kind,
                  slotEdge == edge else {
                return false
            }
            return slot.layout != nil
        }
        .sorted { $0.id.rawValue < $1.id.rawValue }
        .compactMap(chromeRailSlot)
}

private func collapsedChromeRailSlot(edge: WorkspaceEdge,
                                     document: WorkspaceDocument) -> _WorkspaceRailSlot? {
    chromeRailSlots(edge: edge, document: document).first
        ?? (!collapsedGroups(on: edge, document: document).isEmpty ? fallbackChromeRailSlot(edge: edge) : nil)
}

private func chromeRailSlot(_ slot: WorkspaceSlot) -> _WorkspaceRailSlot? {
    guard case .chrome(let edge, _) = slot.kind else {
        return nil
    }
    return _WorkspaceRailSlot(id: slot.id,
                              edge: edge,
                              thickness: chromeThickness(slot))
}

private func chromeThickness(_ slot: WorkspaceSlot) -> Float {
    if case .chrome(_, let size) = slot.kind,
       let fixed = size.fixedValue {
        return fixed
    }
    return _WorkspaceMetrics.railThickness
}

private func fallbackChromeRailSlot(edge: WorkspaceEdge) -> _WorkspaceRailSlot {
    _WorkspaceRailSlot(id: .chromeRail(for: edge),
                       edge: edge,
                       thickness: _WorkspaceMetrics.railThickness)
}

private func railEdge(slotID: WorkspaceSlotID,
                      document: WorkspaceDocument) -> WorkspaceEdge {
    if case .chrome(let edge, _) = document.slot(slotID).kind {
        return edge
    }
    switch slotID {
    case .leading:
        return .leading
    case .trailing:
        return .trailing
    case .top:
        return .top
    default:
        return .bottom
    }
}

private func resolveWorkspaceSplitFraction(splitID: WorkspaceSplitID,
                                           axis: _WorkspaceSplitAxis,
                                           x: Float,
                                           y: Float,
                                           from node: Node) -> Float? {
    guard let root = workspaceRoot(from: node) else { return nil }
    let point = CGPoint(x: CGFloat(x), y: CGFloat(y))

    switch splitID.rawValue {
    case "leading":
        guard axis == .vertical,
              let leading = firstNode(rootedAt: root, debugName: "workspace-region-leading"),
              let center = firstNode(rootedAt: root, debugName: "workspace-center-column") else {
            return nil
        }
        let leadingFrame = absoluteFrame(of: leading)
        let centerFrame = absoluteFrame(of: center)
        let minX = leadingFrame.minX
        let maxX = centerFrame.maxX
        return Float((point.x - minX) / max(maxX - minX, 1))
    case "centerTrailing":
        guard axis == .vertical,
              let center = firstNode(rootedAt: root, debugName: "workspace-center-column"),
              let trailing = firstNode(rootedAt: root, debugName: "workspace-region-trailing") else {
            return nil
        }
        let centerFrame = absoluteFrame(of: center)
        let trailingFrame = absoluteFrame(of: trailing)
        let minX = centerFrame.minX
        let maxX = trailingFrame.maxX
        return Float((point.x - minX) / max(maxX - minX, 1))
    case "topBottom":
        guard axis == .horizontal,
              let center = firstNode(rootedAt: root, debugName: "workspace-region-center"),
              let bottom = firstNode(rootedAt: root, debugName: "workspace-bottom-slot") else {
            return nil
        }
        let centerFrame = absoluteFrame(of: center)
        let bottomFrame = absoluteFrame(of: bottom)
        let minY = centerFrame.minY
        let maxY = bottomFrame.maxY
        return Float((point.y - minY) / max(maxY - minY, 1))
    default:
        return nil
    }
}

private func resolveWorkspaceDragResolution(x: Float,
                                            y: Float,
                                            sourceGroupID: WorkspaceTabGroupID,
                                            sourcePanelID: WorkspacePanelID,
                                            document: WorkspaceDocument,
                                            from node: Node) -> _WorkspaceDragResolution? {
    if let resolution = resolveWorkspaceTabReorderResolution(x: x,
                                                             y: y,
                                                             sourceGroupID: sourceGroupID,
                                                             sourcePanelID: sourcePanelID,
                                                             document: document,
                                                             from: node) {
        return resolution
    }
    if let preview = resolveWorkspaceDropPreview(x: x,
                                                 y: y,
                                                 sourceGroupID: sourceGroupID,
                                                 sourcePanelID: sourcePanelID,
                                                 document: document,
                                                 from: node) {
        return .drop(preview)
    }
    return nil
}

private func resolveWorkspaceTabReorderResolution(x: Float,
                                                  y: Float,
                                                  sourceGroupID: WorkspaceTabGroupID,
                                                  sourcePanelID: WorkspacePanelID,
                                                  document: WorkspaceDocument,
                                                  from node: Node) -> _WorkspaceDragResolution? {
    guard let root = workspaceRoot(from: node),
          let group = document.groups[sourceGroupID],
          let groupNode = firstNode(rootedAt: root,
                                    debugName: "workspace-group-\(sourceGroupID.rawValue)") else {
        return nil
    }
    let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
    let groupFrame = absoluteFrame(of: groupNode)
    guard groupFrame.contains(point) else { return nil }

    let tabFrames = workspaceTabFrames(for: group, rootedAt: root)
    guard !tabFrames.isEmpty else { return nil }

    let tabBand = tabFrames.reduce(tabFrames[0].1) { partial, item in
        partial.union(item.1)
    }.insetBy(dx: -10, dy: -8)
    guard tabBand.contains(point) else { return nil }
    guard group.panels.count > 1,
          let oldIndex = group.panels.firstIndex(of: sourcePanelID) else {
        return .noop
    }

    let targetIndex: Int
    if let indexed = tabFrames.enumerated().first(where: { point.x < $0.element.1.midX }) {
        targetIndex = indexed.offset
    } else {
        targetIndex = group.panels.count
    }
    guard targetIndex != oldIndex, targetIndex != oldIndex + 1 else { return .noop }

    let lineX: CGFloat
    if targetIndex <= 0 {
        lineX = tabFrames[0].1.minX
    } else if targetIndex >= tabFrames.count {
        lineX = tabFrames[tabFrames.count - 1].1.maxX
    } else {
        lineX = tabFrames[targetIndex].1.minX
    }
    let lineFrame = CGRect(x: lineX - 1.5,
                           y: tabBand.minY + 5,
                           width: 3,
                           height: max(12, tabBand.height - 10))
    return .reorder(_WorkspaceReorderPreview(groupID: sourceGroupID,
                                             targetIndex: targetIndex,
                                             lineFrame: lineFrame))
}

private func workspaceTabBand(for group: WorkspaceTabGroup,
                              rootedAt root: Node) -> CGRect? {
    let tabFrames = workspaceTabFrames(for: group, rootedAt: root)
    guard !tabFrames.isEmpty else { return nil }
    return tabFrames.reduce(tabFrames[0].1) { partial, item in
        partial.union(item.1)
    }.insetBy(dx: -10, dy: -8)
}

private func workspaceTabFrames(for group: WorkspaceTabGroup,
                                rootedAt root: Node) -> [(WorkspacePanelID, CGRect)] {
    group.panels.compactMap { panelID -> (WorkspacePanelID, CGRect)? in
        guard let tabNode = firstNode(rootedAt: root,
                                      debugName: "workspace-tab-\(panelID.rawValue)") else {
            return nil
        }
        let frame = absoluteFrame(of: tabNode)
        guard frame.width > 0, frame.height > 0 else { return nil }
        return (panelID, frame)
    }
}

private func resolveWorkspaceDropPreview(x: Float,
                                         y: Float,
                                         sourceGroupID: WorkspaceTabGroupID,
                                         sourcePanelID: WorkspacePanelID,
                                         document: WorkspaceDocument,
                                         from node: Node) -> _WorkspaceDropPreview? {
    guard let root = workspaceRoot(from: node) else { return nil }
    let point = CGPoint(x: CGFloat(x), y: CGFloat(y))

    let visibleGroupIDs = document.slots.values.flatMap { slot in
        (slot.layout?.leafGroupIDs ?? []).filter { document.groups[$0]?.isCollapsed == false }
    }
    for groupID in visibleGroupIDs {
        guard let groupNode = firstNode(rootedAt: root,
                                        debugName: "workspace-group-\(groupID.rawValue)") else {
            continue
        }
        let frame = absoluteFrame(of: groupNode)
        guard frame.contains(point) else { continue }
        guard let slotID = document.slotContaining(groupID: groupID) else { continue }
        if let group = document.groups[groupID],
           let tabBand = workspaceTabBand(for: group, rootedAt: root),
           tabBand.contains(point) {
            return _WorkspaceDropPreview(target: .tabGroup(slot: slotID, groupID: groupID),
                                         frame: frame.insetBy(dx: frame.width * 0.24,
                                                              dy: frame.height * 0.24))
        }
        var preview = dropPreview(in: frame,
                                  point: point,
                                  slotID: slotID,
                                  groupID: groupID)
        if groupID == sourceGroupID, preview.target.placement == .tabGroup {
            preview.target = WorkspaceTarget(slot: slotID, groupID: groupID, placement: .tabGroup)
        }
        return preview
    }

    for slotID in document.slots.keys {
        guard slotID != .center || document.panels[sourcePanelID]?.isDraggable != false,
              let slotNode = firstNode(rootedAt: root,
                                         debugName: "workspace-region-\(slotID.rawValue)") else {
            continue
        }
        let frame = absoluteFrame(of: slotNode)
        guard frame.contains(point) else { continue }
        return _WorkspaceDropPreview(target: WorkspaceTarget.slot(slotID),
                                     frame: frame)
    }

    return nil
}

private func dropPreview(in frame: CGRect,
                         point: CGPoint,
                         slotID: WorkspaceSlotID,
                         groupID: WorkspaceTabGroupID) -> _WorkspaceDropPreview {
    let localX = Float((point.x - frame.minX) / max(frame.width, 1))
    let localY = Float((point.y - frame.minY) / max(frame.height, 1))
    let edge: Float = 0.24
    if localX < edge {
        return _WorkspaceDropPreview(target: .split(slot: slotID, anchorGroupID: groupID, edge: .leading),
                                     frame: CGRect(x: frame.minX,
                                                   y: frame.minY,
                                                   width: frame.width * CGFloat(edge),
                                                   height: frame.height))
    }
    if localX > 1 - edge {
        let width = frame.width * CGFloat(edge)
        return _WorkspaceDropPreview(target: .split(slot: slotID, anchorGroupID: groupID, edge: .trailing),
                                     frame: CGRect(x: frame.maxX - width,
                                                   y: frame.minY,
                                                   width: width,
                                                   height: frame.height))
    }
    if localY < edge {
        return _WorkspaceDropPreview(target: .split(slot: slotID, anchorGroupID: groupID, edge: .top),
                                     frame: CGRect(x: frame.minX,
                                                   y: frame.minY,
                                                   width: frame.width,
                                                   height: frame.height * CGFloat(edge)))
    }
    if localY > 1 - edge {
        let height = frame.height * CGFloat(edge)
        return _WorkspaceDropPreview(target: .split(slot: slotID, anchorGroupID: groupID, edge: .bottom),
                                     frame: CGRect(x: frame.minX,
                                                   y: frame.maxY - height,
                                                   width: frame.width,
                                                   height: height))
    }
    return _WorkspaceDropPreview(target: .tabGroup(slot: slotID, groupID: groupID),
                                 frame: frame.insetBy(dx: frame.width * CGFloat(edge),
                                                      dy: frame.height * CGFloat(edge)))
}

private func workspaceRoot(from node: Node) -> Node? {
    var cursor: Node? = node
    var fallback: Node?
    while let current = cursor {
        if (current.attachments[LayoutDebugAttachmentKey.debugName] as? String) == "workspace" {
            return current
        }
        fallback = current
        cursor = current.parent
    }
    return fallback
}

private func firstNode(rootedAt root: Node, debugName: String) -> Node? {
    if (root.attachments[LayoutDebugAttachmentKey.debugName] as? String) == debugName {
        return root
    }
    for child in root.children {
        if let found = firstNode(rootedAt: child, debugName: debugName) {
            return found
        }
    }
    return nil
}

private func absoluteFrame(of node: Node) -> CGRect {
    node.absoluteFrame
}

private enum WorkspaceIcons {
    static let collapse = BundleImageResource.svg(named: "collapse",
                                                  in: GuavaUIWorkspaceResourceBundle.bundle,
                                                  subdirectory: "WorkspaceIcons")
    static let panelLeading = BundleImageResource.svg(named: "panel-leading",
                                                      in: GuavaUIWorkspaceResourceBundle.bundle,
                                                      subdirectory: "WorkspaceIcons")
    static let panelTrailing = BundleImageResource.svg(named: "panel-trailing",
                                                       in: GuavaUIWorkspaceResourceBundle.bundle,
                                                       subdirectory: "WorkspaceIcons")
    static let panelTop = BundleImageResource.svg(named: "panel-top",
                                                  in: GuavaUIWorkspaceResourceBundle.bundle,
                                                  subdirectory: "WorkspaceIcons")
    static let panelBottom = BundleImageResource.svg(named: "panel-bottom",
                                                     in: GuavaUIWorkspaceResourceBundle.bundle,
                                                     subdirectory: "WorkspaceIcons")

    /// Slot-aware collapse glyph: a panel frame with the docked side filled
    /// (VS Code-style), falling back to the plain dash for exotic slots.
    static func collapse(for slot: WorkspaceSlotID?) -> BundleImageResource {
        switch slot {
        case .some(.leading):  return panelLeading
        case .some(.trailing): return panelTrailing
        case .some(.top):      return panelTop
        case .some(.bottom):   return panelBottom
        default:               return collapse
        }
    }
    static let expandRight = BundleImageResource.svg(named: "expand-right",
                                                     in: GuavaUIWorkspaceResourceBundle.bundle,
                                                     subdirectory: "WorkspaceIcons")
    static let expandDown = BundleImageResource.svg(named: "expand-down",
                                                    in: GuavaUIWorkspaceResourceBundle.bundle,
                                                    subdirectory: "WorkspaceIcons")
    static let close = BundleImageResource.svg(named: "close",
                                               in: GuavaUIWorkspaceResourceBundle.bundle,
                                               subdirectory: "WorkspaceIcons")
    static let pinDot = BundleImageResource.svg(named: "pin-dot",
                                                in: GuavaUIWorkspaceResourceBundle.bundle,
                                                subdirectory: "WorkspaceIcons")
}
