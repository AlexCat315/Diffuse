#if canImport(CoreGraphics)
import CoreGraphics
#endif
import GuavaUICompose
import GuavaUIRuntime

private enum _WorkspaceMetrics {
    static let railThickness: Float = 40
}

/// Card chrome shared by docked groups and floating windows.
///
/// A workspace is a set of cards resting on the window canvas, not a grid of
/// outlined rectangles: the group carries the design system's panel radius, a
/// single soft hairline and one shallow shadow, and the gutters between groups
/// stay narrow enough that the cards dominate. Callers that already own a
/// stronger elevation (a floating window) can apply their own shadow after this
/// and win.
private extension View {
    func workspaceCardSurface(_ fill: SemanticColorRef) -> some View {
        WorkspacePanelStyleReader { style in
            ThemeReader { theme in
                switch style {
                case .continuous:
                    self.background(fill).clipped()
                case .soft:
                    self.background(fill).cornerRadius(theme.radius.lg).clipped()
                case .card:
                    self
                        .background(fill)
                        .cornerRadius(theme.radius.xl)
                        .border(theme.colors.border.multipliedAlpha(0.55), width: 1)
                        .shadow(color: theme.elevation.low.color ?? .clear, offsetY: 2, blur: 8)
                        .clipped()
                }
            }
        }
    }
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
    public var compact: Bool = false

    @State private var version: UInt64 = 0
    @State private var subscriptionIdentity = WorkspaceSubscriptionIdentity()

    public init(controller: WorkspaceController, compact: Bool = false,
                content: @escaping (WorkspacePanelID) -> AnyView) {
        self.controller = controller
        self.compact = compact
        self.content = content
    }

    public init(controller: WorkspaceController, registry: WorkspacePanelRegistry, compact: Bool = false) {
        self.init(controller: controller, compact: compact, content: { registry.make($0) })
    }

    public var body: some View {
        let _ = version
        let document = controller.document
        let bind = $version
        let _ = WorkspaceControllerSubscription.acquire(controller: controller,
                                                        tag: ObjectIdentifier(subscriptionIdentity),
                                                        bind: bind)
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if let panelID = controller.maximizedPanelID, let panel = document.panels[panelID] {
                Row(alignment: .center, spacing: 8) {
                    Text(panel.title).font(.label).flex()
                    Button("Restore") { _ = controller.dispatch(.restoreMaximized) }.buttonStyle(.ghost)
                }.padding(6)
                content(panelID).flex().frame(minWidth: 0, minHeight: 0)
            } else {
            SurfaceReader { surface in
            if compact || surface.viewport.widthClass != .expanded {
                _WorkspaceCompactView(document: document, controller: controller, content: content).flex()
            } else {
            WorkspaceMetricsReader { metrics in
                _WorkspaceShell(document: document, controller: controller, content: content, metrics: metrics)
            }
                .flex()
                .frame(minWidth: 0, minHeight: 0)
            _WorkspaceFloatingLayer(document: document,
                                    controller: controller,
                                    content: content)
            }
            }
            }
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

private struct _WorkspaceCompactView: View {
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView
    @State private var isPresented = false

    var body: some View {
        let panels = document.panels.values.filter { document.groupContaining(panelID: $0.id) != nil }
            .sorted { $0.title < $1.title }
        let selected = controller.focusedPanelID.flatMap { id in panels.first { $0.id == id } }
            ?? panels.first { $0.id.rawValue == "viewport" } ?? panels.first
        Column(alignment: .leading, spacing: 0) {
            if let selected {
                Popover(isPresented: $isPresented, width: 240, surface: .content, overflow: .flip) {
                    Text(selected.title + " ▾").font(.label).padding(8)
                } content: {
                    Menu(panels.map { panel in
                        .item(MenuItem(id: panel.id.rawValue, title: panel.title,
                            isSelected: panel.id == selected.id, action: {
                                guard let group = document.groupContaining(panelID: panel.id) else { return }
                                _ = controller.dispatch(.setActivePanel(groupID: group.id, panelID: panel.id))
                                isPresented = false
                            }))
                    }, width: 240)
                }
                Divider()
                content(selected.id).flex().frame(width: .percent(100), minWidth: 0, minHeight: 0)
            }
        }.frame(width: .percent(100), minWidth: 0, minHeight: 0)
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
    let metrics: WorkspaceLayoutMetrics
    @State private var height: Float = 0

    var body: some View {
        let topVisible = !visibleGroups(in: .top, document: document).isEmpty
        let topCollapsed = !collapsedGroups(in: .top, document: document).isEmpty
        let topChrome = chromeRailSlots(edge: .top, document: document)
        let bottomChrome = visibleChromeRailSlots(edge: .bottom, document: document)
        let reserve = topChrome.reduce(0) { $0 + $1.thickness }
            + bottomChrome.reduce(0) { $0 + $1.thickness } + (topCollapsed ? 40 : 0)
        let resolver = WorkspaceSizingResolver(document: document, metrics: metrics)
        let centerBottom = resolver.combine(resolver.slot(.center, axis: .vertical),
            resolver.slot(.bottom, axis: .vertical), stacked: true,
            gap: visibleGroups(in: .bottom, document: document).isEmpty ? 0 : metrics.divider)
        let mainSize = resolver.combine(centerBottom,
            resolver.combine(resolver.slot(.leading, axis: .vertical),
                             resolver.slot(.trailing, axis: .vertical), stacked: false), stacked: false)
        let split = WorkspaceResolvedSplit(fraction: document.splitFractions.top, fallback: 0.25,
            available: height - reserve - (topVisible ? metrics.divider : 0),
            first: resolver.slot(.top, axis: .vertical), second: mainSize)
        let phase = [topVisible]
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            topChrome.map { slot in
                AnyView(_WorkspaceChromeSlot(slot: slot, document: document, controller: controller)
                    .id("workspace-chrome-\(slot.id.rawValue)"))
            }
            WorkspaceRegionTransition(isVisible: topVisible, horizontal: false,
                sizing: .fraction(split.fraction), phase: phase,
                content: AnyView(_WorkspaceSlotView(slotID: .top, document: document,
                    controller: controller, content: content).flex().frame(minWidth: 0, minHeight: 0)))
                .id("workspace-region-top-transition")
            WorkspaceRegionTransition(isVisible: topVisible, horizontal: false,
                sizing: .divider, phase: phase,
                content: AnyView(_WorkspaceSplitDivider(splitID: "top", axis: .horizontal,
                    controller: controller).frame(width: .percent(100), height: .percent(100))
                    .debugName("workspace-split-top")))
                .id("workspace-split-top")
            if topCollapsed {
                _WorkspaceRail(slotID: .top, document: document, controller: controller)
                    .id("workspace-rail-top")
            }
            _WorkspaceMainRow(document: document, controller: controller, content: content, metrics: metrics)
                .flex(topVisible ? 1 - split.fraction : 1, shrink: 1, basis: 0)
                .frame(minWidth: 0, minHeight: 0)
                .modifier(_WorkspaceLayoutAnimation(phase: phase))
            bottomChrome.map { slot in
                AnyView(_WorkspaceChromeSlot(slot: slot, document: document, controller: controller)
                    .id("workspace-chrome-\(slot.id.rawValue)"))
            }
        }
        .background(.background)
        .flex()
        .frame(minWidth: 0, minHeight: 0)
        .modifier(WorkspaceExtentObserver(horizontal: false, extent: $height))
        .modifier(WorkspaceResizeGeometryModifier(values: [
            WorkspaceResizeGeometry(splitID: "top", horizontal: false,
                offset: topChrome.reduce(0) { $0 + $1.thickness } + metrics.divider / 2, split: split)
        ]))
    }
}

private struct _WorkspaceMainRow: View {
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView
    let metrics: WorkspaceLayoutMetrics
    @State private var width: Float = 0

    var body: some View {
        let leadingVisible = !visibleGroups(in: .leading, document: document).isEmpty
        let leadingRail = railPlan(edge: .leading, document: document)
        let trailingVisible = !visibleGroups(in: .trailing, document: document).isEmpty
        let trailingRail = railPlan(edge: .trailing, document: document)
        let resolver = WorkspaceSizingResolver(document: document, metrics: metrics)
        let centerSize = resolver.combine(resolver.slot(.center, axis: .horizontal),
                                          resolver.slot(.bottom, axis: .horizontal), stacked: false)
        let leadingSize = resolver.slot(.leading, axis: .horizontal)
        let trailingSize = resolver.slot(.trailing, axis: .horizontal)
        let railWidth = (leadingRail?.slot.thickness ?? 0) + (trailingRail?.slot.thickness ?? 0)
        let available = max(0, width - railWidth - metrics.divider * Float((leadingVisible ? 1 : 0) + (trailingVisible ? 1 : 0)))
        let leadingSplit = WorkspaceResolvedSplit(fraction: document.splitFractions.leading,
            fallback: 0.22, available: available, first: leadingSize,
            second: trailingVisible ? resolver.combine(centerSize, trailingSize, stacked: true) : centerSize)
        let leadingWeight = leadingVisible ? leadingSplit.fraction : 0
        let trailingSplit = WorkspaceResolvedSplit(fraction: document.splitFractions.centerTrailing,
            fallback: 0.78, available: available * (1 - leadingWeight), first: centerSize, second: trailingSize)
        let centerWeight = (1 - leadingWeight) * (trailingVisible ? trailingSplit.fraction : 1)
        let trailingWeight = (1 - leadingWeight) - centerWeight
        let phase = [leadingVisible, trailingVisible]
        Box(direction: .row, alignItems: .stretch, spacing: 0) {
            WorkspaceRegionTransition(isVisible: leadingRail != nil, horizontal: true,
                                      sizing: .points(leadingRail?.slot.thickness ?? 40), phase: phase,
                                      content: AnyView(Box(direction: .column, alignItems: .stretch) {
                if let leadingRail {
                    _WorkspaceRail(slotID: leadingRail.slot.id, edgeOverride: leadingRail.slot.edge,
                                   thickness: leadingRail.slot.thickness, groupsOverride: leadingRail.groups,
                                   document: document, controller: controller)
                        .id("workspace-rail-leading")
                }
            }))
            WorkspaceRegionTransition(isVisible: leadingVisible, horizontal: true,
                                      sizing: .fraction(leadingWeight), phase: phase,
                                      content: AnyView(_WorkspaceSideRegion(slotID: .leading,
                                          document: document, controller: controller, content: content)
                                          .flex()
                                          .frame(minWidth: 0, minHeight: 0)))
                .id("workspace-region-leading")
            WorkspaceRegionTransition(isVisible: leadingVisible, horizontal: true,
                                      sizing: .divider, phase: phase,
                                      content: AnyView(_WorkspaceSplitDivider(splitID: "leading", axis: .vertical,
                                          controller: controller).frame(width: .percent(100), height: .percent(100))
                                          .debugName("workspace-split-leading")))
                .id("workspace-split-leading")
            _WorkspaceCenterColumn(document: document, controller: controller, content: content, metrics: metrics)
                .debugName("workspace-center-column")
                .id("workspace-center-column")
                .flex(centerWeight, shrink: 1, basis: 0)
                .frame(minWidth: 0, minHeight: 0)
                .modifier(_WorkspaceLayoutAnimation(phase: phase))
            WorkspaceRegionTransition(isVisible: trailingVisible, horizontal: true,
                                      sizing: .divider, phase: phase,
                                      content: AnyView(_WorkspaceSplitDivider(splitID: "centerTrailing", axis: .vertical,
                                          controller: controller).frame(width: .percent(100), height: .percent(100))
                                          .debugName("workspace-split-centerTrailing")))
                .id("workspace-split-centerTrailing")
            WorkspaceRegionTransition(isVisible: trailingVisible, horizontal: true,
                                      sizing: .fraction(trailingWeight), phase: phase,
                                      content: AnyView(_WorkspaceSideRegion(slotID: .trailing,
                                          document: document, controller: controller, content: content)
                                          .flex()
                                          .frame(minWidth: 0, minHeight: 0)))
                .id("workspace-region-trailing")
            WorkspaceRegionTransition(isVisible: trailingRail != nil, horizontal: true,
                                      sizing: .points(trailingRail?.slot.thickness ?? 40), phase: phase,
                                      content: AnyView(Box(direction: .column, alignItems: .stretch) {
                if let trailingRail {
                    _WorkspaceRail(slotID: trailingRail.slot.id, edgeOverride: trailingRail.slot.edge,
                                   thickness: trailingRail.slot.thickness, groupsOverride: trailingRail.groups,
                                   document: document, controller: controller)
                        .id("workspace-rail-trailing")
                }
            }))
        }
        .background(.background)
        .flex()
        .frame(minWidth: 0, minHeight: 0)
        .modifier(WorkspaceExtentObserver(horizontal: true, extent: $width))
        .modifier(WorkspaceResizeGeometryModifier(values: [
            WorkspaceResizeGeometry(splitID: "leading", horizontal: true,
                offset: (leadingRail?.slot.thickness ?? 0) + metrics.divider / 2, split: leadingSplit),
            WorkspaceResizeGeometry(splitID: "centerTrailing", horizontal: true,
                offset: (leadingRail?.slot.thickness ?? 0) + leadingWeight * available
                    + (leadingVisible ? metrics.divider : 0) + metrics.divider / 2, split: trailingSplit)
        ]))
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
        WorkspaceMetricsReader { metrics in
            TextScalerReader { scaler in windowBody(metrics: metrics, titleHeight: scaler.scale(30)) }
        }
    }

    private func windowBody(metrics: WorkspaceLayoutMetrics, titleHeight: Float) -> some View {
        let frame = WorkspaceSizingResolver(document: document, metrics: metrics)
            .floatingFrame(window.frame, groupID: group.id, titleHeight: titleHeight)
        return Box(direction: .column, alignItems: .stretch, spacing: 0) {
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
                .frame(width: titleHeight - 6, height: titleHeight - 6)
                .semanticRole("workspace.floating.redock")
                .debugName("workspace-floating-redock-\(window.id.rawValue)")
            }
            .padding(horizontal: 6, vertical: 3)
            .background(.surfaceRaised)
            .frame(height: titleHeight).flex(0, shrink: 0)

            _WorkspaceTabGroupView(group: group,
                                   document: document,
                                   controller: controller,
                                   content: content)
                .flex()
        }
        .workspaceCardSurface(.surfaceFloating)
        .shadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x96),
                offsetY: 12,
                blur: 32)
        .frame(width: frame.width, height: frame.height)
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
                                           height: CGFloat(node.compositionValue(of: TextScalerEnvironment.key).scale(30)))
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
        [Text(window.title).lineLimit(1)
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
    let metrics: WorkspaceLayoutMetrics
    @State private var height: Float = 0

    var body: some View {
        let bottomVisible = !visibleGroups(in: .bottom, document: document).isEmpty
        let bottomRail = bottomVisible ? nil : railPlan(edge: .bottom, document: document)
        let resolver = WorkspaceSizingResolver(document: document, metrics: metrics)
        let split = WorkspaceResolvedSplit(fraction: document.splitFractions.topBottom,
            fallback: 0.74, available: height - (bottomVisible ? metrics.divider : 0),
            first: resolver.slot(.center, axis: .vertical), second: resolver.slot(.bottom, axis: .vertical))
        let phase = [bottomVisible]
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            _WorkspaceSlotView(slotID: .center, document: document, controller: controller, content: content)
                .flex(bottomVisible ? split.fraction : 1, shrink: 1, basis: 0)
                .frame(minWidth: 0, minHeight: 0)
                .modifier(_WorkspaceLayoutAnimation(phase: phase))
            WorkspaceRegionTransition(isVisible: bottomVisible, horizontal: false,
                                      sizing: .divider, phase: phase,
                                      content: AnyView(_WorkspaceSplitDivider(splitID: "topBottom", axis: .horizontal,
                                          controller: controller).frame(width: .percent(100), height: .percent(100))
                                          .debugName("workspace-split-topBottom")))
                .id("workspace-split-topBottom")
            WorkspaceRegionTransition(isVisible: bottomVisible, horizontal: false,
                                      sizing: .fraction(1 - split.fraction), phase: phase,
                                      content: AnyView(_WorkspaceBottomSlot(document: document,
                                          controller: controller, content: content)
                                          .flex()
                                          .frame(minWidth: 0, minHeight: 0)))
                .id("workspace-bottom-transition")
            WorkspaceRegionTransition(isVisible: bottomRail != nil, horizontal: false,
                                      sizing: .points(bottomRail?.slot.thickness ?? 40), phase: phase,
                                      content: AnyView(Box(direction: .column, alignItems: .stretch) {
                if let bottomRail {
                    _WorkspaceChromeSlot(slot: bottomRail.slot, groupsOverride: bottomRail.groups,
                                         document: document, controller: controller)
                        .id("workspace-chrome-\(bottomRail.slot.id.rawValue)")
                }
            }))
        }
        .flex()
        .frame(minWidth: 0, minHeight: 0)
        .modifier(WorkspaceExtentObserver(horizontal: false, extent: $height))
        .modifier(WorkspaceResizeGeometryModifier(values: [
            WorkspaceResizeGeometry(splitID: "topBottom", horizontal: false,
                offset: metrics.divider / 2, split: split)
        ]))
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

private struct _WorkspaceRailReserve: View {
    let slot: _WorkspaceRailSlot

    var body: some View {
        let horizontal = slot.edge == .top || slot.edge == .bottom
        Box { EmptyView() }
            .frame(width: horizontal ? .auto : .points(slot.thickness),
                   height: horizontal ? .points(slot.thickness) : .auto)
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
        .frame(width: horizontal ? .auto : .points(slot.thickness),
               height: horizontal ? .points(slot.thickness) : .auto)
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
                                         slotID: slotID,
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

struct _WorkspaceTabGroupView: View {
    let group: WorkspaceTabGroup
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        let activeID = group.activePanelID ?? group.panels.first
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if !hidesTabBar {
                _WorkspaceTabBar(group: group,
                                 document: document,
                                 controller: controller)
            }
            if let activeID {
                // Every region behaves like CSS `overflow: auto`: the panel is
                // laid out at the region's height, and only content that
                // spills past it (rigid rows a panel cannot shrink) becomes
                // scrollable. A panel with its own scroller clips, so it
                // fits exactly and keeps scrolling itself.
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    ScrollView(.vertical) {
                        content(activeID)
                            .flex(1, shrink: 1, basis: 0)
                            .frame(minWidth: 0, minHeight: 0)
                    }
                    .flex(1, shrink: 1, basis: 0)
                    .frame(minWidth: 0, minHeight: 0)
                    .debugName("workspace-panel-scroll-\(activeID.rawValue)")
                }
                    .flex()
                    .frame(minWidth: 0, minHeight: 0)
                    .clipped()
                    .semanticRole("workspace.panel.content")
                    .accessibility { $0.role = .tabPanel; $0.label = document.panels[activeID]?.title ?? activeID.rawValue }
                    .debugName("workspace-panel-\(activeID.rawValue)")
            } else {
                EmptyView()
                    .flex()
            }
        }
        .workspaceCardSurface(.surfaceRaised)
        .frame(minWidth: 0, minHeight: 0)
        .layoutRole("workspace-tab-group")
        .semanticRole("workspace.group")
        .debugName("workspace-group-\(group.id.rawValue)")
    }

    private var hidesTabBar: Bool {
        group.panels.count == 1 && group.panels.first.flatMap { document.panels[$0] }?.hidesTabBarWhenAlone == true
    }
}

private struct _WorkspaceTabBar: View {
    let group: WorkspaceTabGroup
    let document: WorkspaceDocument
    let controller: WorkspaceController
    @State private var overflowPresented = false

    var body: some View {
        WorkspacePanelStyleReader { style in
            TextScalerReader { scaler in tabBar(scaler: scaler, style: style) }
        }
    }

    private func tabBar(scaler: TextScaler, style: WorkspacePanelStyle) -> some View {
        let slotID = document.slotContaining(groupID: group.id)
        let compactControls = style.usesCompactControls
        let canCollapse = slotID != nil && slotID != .center && group.panels.contains {
            document.panels[$0]?.isCollapsible == true
        }
        let control = max(24, scaler.scale(24))
        let tabButtons = group.panels.compactMap { panelID -> AnyView? in
            guard let panel = document.panels[panelID] else { return nil }
            return AnyView(_WorkspaceTabButton(groupID: group.id, panelID: panelID, title: panel.title,
                isActive: panelID == (group.activePanelID ?? group.panels.first), isPinned: group.isPinned(panelID),
                document: document, controller: controller)
                .flex(0, shrink: 0)
                .semanticRole("workspace.tab")
                .debugName("workspace-tab-\(panelID.rawValue)"))
        }
        return Row(alignment: .center, spacing: 0) {
            ScrollView(.horizontal) {
                Row(alignment: .center, spacing: 0) { tabButtons }
                    .padding(vertical: compactControls && slotID != .center ? 4 : 0)
                    .flex(0, shrink: 0)
                    .accessibility { $0.role = .tabList; $0.label = "Panel tabs"; $0.value = activeTitle }
            }
            .flex(1, shrink: 1, basis: 0)
            .frame(height: .percent(100), minWidth: 0)
            .debugName("workspace-tabs-scroll-\(group.id.rawValue)")
            if group.panels.count > 1 || compactControls {
                Popover(isPresented: $overflowPresented, width: max(240, scaler.scale(200)), placement: .bottomTrailing, surface: .content, overflow: .flip) {
                    Icon(UIIcons.Action.moreHorizontal, size: 12)
                        .frame(width: control, height: control)
                        .accessibility { $0.label = "All panels" }
                } content: {
                    Menu(group.panels.compactMap { panelID in
                        guard let panel = document.panels[panelID] else { return nil }
                        return .item(MenuItem(id: panelID, title: panel.title,
                            isSelected: panelID == group.activePanelID, action: {
                                _ = controller.dispatch(.setActivePanel(groupID: group.id, panelID: panelID))
                                overflowPresented = false
                            }))
                    } + (compactControls ? groupActions(canCollapse: canCollapse) : []),
                    width: max(240, scaler.scale(200)), onDismiss: { overflowPresented = false })
                }
                .flex(0, shrink: 0)
                .semanticRole("workspace.tabs.overflow")
                .debugName("workspace-tabs-overflow-\(group.id.rawValue)")
            }
            if !compactControls, let panelID = group.activePanelID {
                Button(icon: .resource(UIIcons.Navigation.expand), size: 12, tooltip: "Maximize") {
                    _ = controller.dispatch(.toggleMaximize(panelID))
                }
                .buttonStyle(.ghost).frame(width: control, height: control).flex(0, shrink: 0)
                .debugName("workspace-maximize-\(group.id.rawValue)")
            }
            if canCollapse && !compactControls {
                Button(icon: .resource(WorkspaceIcons.collapse(for: slotID)), size: 12, tooltip: "Collapse") {
                    _ = controller.dispatch(.collapse(group.id))
                }
                .buttonStyle(.ghost).frame(width: control, height: control).flex(0, shrink: 0)
                .semanticRole("workspace.group.collapse")
                .debugName("workspace-collapse-\(group.id.rawValue)")
            }
        }
        .padding(horizontal: 4, vertical: 0)
        .background(.surface)
        .modifier(_WorkspaceTabBarHeight())
        .layoutRole("workspace-tab-bar")
        .accessibility { $0.role = .group; $0.label = "Panel tab bar" }
    }

    private var activeTitle: String {
        (group.activePanelID ?? group.panels.first).flatMap { document.panels[$0]?.title } ?? ""
    }

    private func groupActions(canCollapse: Bool) -> [MenuEntry] {
        var entries: [MenuEntry] = [.separator("group-actions")]
        if let panelID = group.activePanelID {
            entries.append(.item(MenuItem(id: "maximize", title: "Maximize", action: {
                _ = controller.dispatch(.toggleMaximize(panelID))
                overflowPresented = false
            })))
        }
        if canCollapse {
            entries.append(.item(MenuItem(id: "collapse", title: "Collapse", action: {
                _ = controller.dispatch(.collapse(group.id))
                overflowPresented = false
            })))
        }
        return entries
    }
}

private struct _WorkspaceTabBarHeight: ViewModifier {
    func apply(node: Node) {
        node.layoutNode?.height = max(26, node.compositionValue(of: TextScalerEnvironment.key).scale(resolveWorkspaceTheme(on: node).tabBarHeight))
        node.layoutNode?.flexShrink = 0
    }
}

/// The tab owns this callback, leaving ScrollView's measurement/motion callback
/// intact. Only a new active tab or changed geometry moves the scroll position.
private func updateWorkspaceTabReveal(_ node: Node, groupID: WorkspaceTabGroupID, isActive: Bool) {
    let key = "workspace.tabs.revealedGeometry"
    guard isActive else {
        node.attachments.removeValue(forKey: key)
        node.layoutDidUpdate = nil
        return
    }
    node.layoutDidUpdate = { [weak node] _ in
        guard let node else { return }
        var ancestor = node.parent
        while let current = ancestor {
            if current.attachments[LayoutDebugAttachmentKey.debugName] as? String == "workspace-tabs-scroll-\(groupID.rawValue)" {
                let geometry = CGSize(width: current.frame.width, height: node.frame.width)
                guard geometry.width > 0, geometry.height > 0,
                      node.attachments[key] as? CGSize != geometry else { return }
                node.attachments[key] = geometry
                let frame = node.absoluteFrame
                let viewport = current.absoluteFrame
                let delta = frame.minX < viewport.minX || frame.width > viewport.width ? frame.minX - viewport.minX
                    : max(0, frame.maxX - viewport.maxX)
                if abs(delta) > 0.01 { current.contentOffset.x = max(0, current.contentOffset.x + delta) }
                return
            }
            ancestor = current.parent
        }
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
        node.isTabStop = isActive
        updateWorkspaceTabReveal(node, groupID: groupID, isActive: isActive)
        let position = controller.document.groups[groupID].flatMap { $0.panels.firstIndex(of: panelID) }
        let count = controller.document.groups[groupID]?.panels.count ?? 1
        node.accessibility = AccessibilitySemantics(.tab) {
            $0.label = title
            $0.value = isPinned ? "Pinned" : ""
            $0.help = position.map { "Tab \($0 + 1) of \(count)" } ?? ""
            $0.identifier = panelID.rawValue
            $0.state.isSelected = isActive
            $0.combinesChildren = true
        }
        node.accessibilityActions.activate = onClick
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

        registry.setKey(node) { event, phase in
            guard phase == .target, event.modifiers.isDisjoint(with: [.ctrl, .gui, .alt]) else { return .ignored }
            if event.scancode == Scancode.return || event.scancode == Scancode.space { click(); return .handled }
            guard [Scancode.arrowLeft, Scancode.arrowRight, Scancode.home, Scancode.end].contains(event.scancode),
                  let command = workspaceTabCommand(for: event.scancode, rightToLeft: node.resolvesRightToLeft),
                  let group = controller.document.groups[groupID],
                  let target = command.destination(in: group.panels, from: panelID) else { return .ignored }
            _ = controller.dispatch(.setActivePanel(groupID: groupID, panelID: target))
            if let root = workspaceRoot(from: node),
               let targetNode = firstNode(rootedAt: root, debugName: "workspace-tab-\(target.rawValue)") {
                node.isTabStop = false
                targetNode.isTabStop = true
                FocusChainHolder.current?.focus(targetNode)
            }
            return .handled
        }
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
                FocusChainHolder.current?.focus(node, visible: false)
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
            if !state.didDrag, document.panels[panelID]?.isDraggable != false, max(abs(dx), abs(dy)) >= 4 {
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
        let workspace = resolveWorkspaceTheme(on: node)
        let height = max(26, node.compositionValue(of: TextScalerEnvironment.key).scale(workspace.tabBarHeight))
        // Soft panes use selection blocks everywhere; a top rule would cut the rounded corner.
        let style = workspace.panelStyle.usesCompactControls
            ? AnyButtonStyle(WorkspaceContinuousTabStyle(height: height,
                isStage: workspace.panelStyle == .continuous && document.slotContaining(groupID: groupID) == .center))
            : AnyButtonStyle(TabButtonStyle(height: height))
        // Resolve the title color eagerly from this (parented) host node's theme
        // and pass it to `Text` directly. The button style's deferred
        // `.foregroundColor(.onSurface)` resolves against the *label* node's
        // theme at apply-time, and that label — built deep inside this
        // primitive's `_children` — isn't parented under the theme provider yet,
        // so it falls back to `.defaultDark` and bakes near-white tab titles in
        // light mode. `node.theme` here is correct (it already drives the tab bg).
        let titleColor = isActive ? node.theme.colors.onSurface : node.theme.colors.onSurfaceMuted
        let config = ButtonStyleConfiguration(label: AnyView(Row(alignment: .center, spacing: 4) {
                                                  if let key = document.panels[panelID]?.iconAssetKey,
                                                     let resource = WorkspacePanelIconCatalog.resolve(key) {
                                                      Icon(resource, size: 12, color: titleColor)
                                                  }
                                                  if isPinned {
                                                      Icon(WorkspaceIcons.pinDot, size: 6, color: titleColor)
                                                  }
                                                  Text(title, color: titleColor).lineLimit(1).font(.label)
                                                      .frame(maxWidth: node.compositionValue(of: TextScalerEnvironment.key).scale(240))
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
        node.isFocusable = true
        node.isTabStop = true
        node.animatableSet(\.backgroundColor, to: nil)
        switch axis {
        case .vertical: node.layoutNode?.width = hitSize
        case .horizontal: node.layoutNode?.height = hitSize
        }
        node.accessibility = AccessibilitySemantics(.slider) {
            $0.label = "Resize \(splitID.rawValue) workspace region"
            $0.help = axis == .vertical ? "Left and Right to resize; Home and End for limits" : "Up and Down to resize; Home and End for limits"
        }
        let available = workspaceResizeGeometry(splitID, from: node)?.1.split.available ?? 0
        node.accessibilityValueProvider = AccessibilityValueProvider(
            revision: AnyHashable(AccessibilityRevision(version: controller.version, available: available))) { [weak node] in
            guard let node, let (_, geometry) = workspaceResizeGeometry(splitID, from: node) else { return "" }
            return "\(Int((currentFraction(geometry) * 100).rounded()))%"
        }
        node.accessibilityActions.increment = { [weak node] in if let node { adjust(node, by: 0.02) } }
        node.accessibilityActions.decrement = { [weak node] in if let node { adjust(node, by: -0.02) } }
        guard let registry = InteractionRegistryHolder.current else { return }
        let route = InputHandlerRoute(role: .workspace, priority: .capture, debugName: "workspace.split")
        registry.setPointer(node, route: route) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                FocusChainHolder.current?.focus(node, visible: false)
                PointerCaptureHolder.current?.acquire(node)
            case .up:
                if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
            }
            return .handled
        }
        registry.setMotion(node, route: route) { event, _ in
            guard PointerCaptureHolder.current?.target === node,
                  let (container, geometry) = workspaceResizeGeometry(splitID, from: node),
                  geometry.split.available > 0 else { return .ignored }
            let origin = container.absoluteOrigin
            let position = geometry.horizontal ? event.x - Float(origin.x) : event.y - Float(origin.y)
            write((position - geometry.offset) / geometry.split.available, geometry: geometry)
            return .handled
        }
        registry.setKey(node) { event, phase in
            guard phase == .target, event.modifiers.isDisjoint(with: [.ctrl, .gui, .alt]),
                  let (_, geometry) = workspaceResizeGeometry(splitID, from: node) else { return .ignored }
            let step: Float = event.modifiers.contains(.shift) ? 0.1 : 0.02
            switch event.scancode {
            case Scancode.home: write(geometry.split.range.lowerBound, geometry: geometry)
            case Scancode.end: write(geometry.split.range.upperBound, geometry: geometry)
            case Scancode.arrowLeft where axis == .vertical, Scancode.arrowUp where axis == .horizontal:
                adjust(node, by: -step)
            case Scancode.arrowRight where axis == .vertical, Scancode.arrowDown where axis == .horizontal:
                adjust(node, by: step)
            default: return .ignored
            }
            return .handled
        }
    }

    private struct AccessibilityRevision: Hashable {
        let version: UInt64
        let available: Float
    }

    private func currentFraction(_ geometry: WorkspaceResizeGeometry) -> Float {
        let saved: Float?
        switch splitID.rawValue {
        case "leading": saved = controller.document.splitFractions.leading
        case "centerTrailing": saved = controller.document.splitFractions.centerTrailing
        case "topBottom": saved = controller.document.splitFractions.topBottom
        case "top": saved = controller.document.splitFractions.top
        default: saved = nil
        }
        let value = saved ?? geometry.split.fraction
        return max(geometry.split.range.lowerBound, min(geometry.split.range.upperBound, value))
    }

    private func write(_ value: Float, geometry: WorkspaceResizeGeometry) {
        guard value.isFinite else { return }
        _ = controller.dispatch(.resizeSplit(splitID,
            fraction: max(geometry.split.range.lowerBound, min(geometry.split.range.upperBound, value))))
    }

    private func adjust(_ node: Node, by delta: Float) {
        guard let (_, geometry) = workspaceResizeGeometry(splitID, from: node) else { return }
        write(currentFraction(geometry) + delta, geometry: geometry)
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
        // The hairline between two cards. The parent keeps the invisible grab
        // area around it, so this node contributes only the visible rule.
        node.animatableSet(\.backgroundColor, to: theme.panelStyle == .soft ? .clear : node.theme.colors.divider)
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
                                             panelID: item.panelID,
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
    let panelID: WorkspacePanelID
    let title: String
    let icon: BundleImageResource?
    let controller: WorkspaceController

    var body: some View {
        // Activity-bar idiom: a collapsed panel is a square icon button whose
        // tooltip carries the title. Text pills are the no-icon fallback only.
        if let icon {
            Button(tooltip: title) {
                _ = controller.dispatch(.setActivePanel(groupID: groupID, panelID: panelID))
                _ = controller.dispatch(.expand(groupID))
            } label: {
                Icon(icon, size: 16, color: .onSurfaceMuted)
                    .padding(horizontal: 6, vertical: 6)
            }
            .buttonStyle(_WorkspaceRailRestoreStyle())
            .semanticRole("workspace.rail.restore")
            .debugName("workspace-restore-\(groupID.rawValue)-\(panelID.rawValue)")
        } else if isHorizontal {
            Button(tooltip: title) {
                _ = controller.dispatch(.setActivePanel(groupID: groupID, panelID: panelID))
                _ = controller.dispatch(.expand(groupID))
            } label: {
                Row(alignment: .center, spacing: 6) {
                    Icon(WorkspaceIcons.expandDown, size: 10, color: .onSurfaceMuted)
                    Text(title)
                        .font(.label)
                }
                .padding(horizontal: 8, vertical: 4)
            }
            .buttonStyle(_WorkspaceRailRestoreStyle())
            .semanticRole("workspace.rail.restore")
            .debugName("workspace-restore-\(groupID.rawValue)-\(panelID.rawValue)")
        } else {
            Button(tooltip: title) {
                _ = controller.dispatch(.setActivePanel(groupID: groupID, panelID: panelID))
                _ = controller.dispatch(.expand(groupID))
            } label: {
                _WorkspaceVerticalTitle(title: title)
            }
            .buttonStyle(_WorkspaceRailRestoreStyle())
            .semanticRole("workspace.rail.restore")
            .debugName("workspace-restore-\(groupID.rawValue)-\(panelID.rawValue)")
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
        .cornerRadius(theme.radius.sm)
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

/// Arrow keys follow the visual strip: in right-to-left layouts the tab after
/// the active one sits to its left, so Left moves forward.
func workspaceTabCommand(for scancode: UInt32, rightToLeft: Bool) -> SelectionNavigation? {
    switch scancode {
    case Scancode.arrowLeft: rightToLeft ? .next : .previous
    case Scancode.arrowRight: rightToLeft ? .previous : .next
    case Scancode.home: .first
    case Scancode.end: .last
    default: nil
    }
}
