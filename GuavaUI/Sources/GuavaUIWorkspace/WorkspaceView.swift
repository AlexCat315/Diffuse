import CoreGraphics
import GuavaUICompose
import GuavaUIRuntime

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
        let bind = $version
        let _ = WorkspaceControllerSubscription.acquire(controller: controller,
                                                        tag: ObjectIdentifier(subscriptionIdentity),
                                                        bind: bind)
        _WorkspaceShell(document: controller.document,
                        controller: controller,
                        content: content)
            .layoutRole("workspace")
            .semanticRole("workspace")
            .debugName("workspace")
    }
}

private final class WorkspaceSubscriptionIdentity {}

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
        let leadingVisible = !visibleGroups(in: .leading, document: document).isEmpty
        let leadingCollapsed = !collapsedGroups(in: .leading, document: document).isEmpty
        let trailingVisible = !visibleGroups(in: .trailing, document: document).isEmpty
        let trailingCollapsed = !collapsedGroups(in: .trailing, document: document).isEmpty
        let weights = WorkspaceShellWeights(document: document,
                                            leadingVisible: leadingVisible,
                                            trailingVisible: trailingVisible)
        Box(direction: .row, alignItems: .stretch, spacing: 0) {
            if leadingCollapsed {
                _WorkspaceRail(regionID: .leading,
                               document: document,
                               controller: controller)
                    .id("workspace-rail-leading")
            }
            if leadingVisible {
                _WorkspaceSideRegion(regionID: .leading,
                                     document: document,
                                     controller: controller,
                                     content: content)
                    .id("workspace-region-leading")
                    .flex(weights.leading, shrink: 1, basis: 0)
            }
            _WorkspaceCenterColumn(document: document,
                                   controller: controller,
                                   content: content)
                .id("workspace-center-column")
                .flex(weights.center, shrink: 1, basis: 0)
            if trailingVisible {
                Divider(axis: .vertical)
                    .id("workspace-divider-trailing")
                _WorkspaceSideRegion(regionID: .trailing,
                                     document: document,
                                     controller: controller,
                                     content: content)
                    .id("workspace-region-trailing")
                    .flex(weights.trailing, shrink: 1, basis: 0)
            }
            if trailingCollapsed {
                _WorkspaceRail(regionID: .trailing,
                               document: document,
                               controller: controller)
                    .id("workspace-rail-trailing")
            }
        }
        .background(.surfaceSunken)
        .flex()
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

private struct _WorkspaceCenterColumn: View {
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        let bottomVisible = !visibleGroups(in: .bottom, document: document).isEmpty
        let bottomCollapsed = !collapsedGroups(in: .bottom, document: document).isEmpty
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            _WorkspaceRegionView(regionID: .center,
                                 document: document,
                                 controller: controller,
                                 content: content)
                .flex(bottomVisible ? document.splitFractions.topBottom : 1,
                      shrink: 1,
                      basis: 0)
            if bottomVisible || bottomCollapsed {
                Divider()
                _WorkspaceBottomSlot(document: document,
                                     controller: controller,
                                     content: content)
                    .flex(bottomVisible ? 1 - document.splitFractions.topBottom : 0,
                          shrink: 1,
                          basis: bottomVisible ? 0 : 40)
            }
        }
        .flex()
    }
}

private struct _WorkspaceSideRegion: View {
    let regionID: WorkspaceRegionID
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        _WorkspaceRegionView(regionID: regionID,
                             document: document,
                             controller: controller,
                             content: content)
    }
}

private struct _WorkspaceBottomSlot: View {
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        let collapsed = collapsedGroups(in: .bottom, document: document)
        let visible = visibleGroups(in: .bottom, document: document)
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if !visible.isEmpty {
                _WorkspaceRegionView(regionID: .bottom,
                                     document: document,
                                     controller: controller,
                                     content: content)
                    .id("workspace-region-bottom")
                    .flex()
            }
            if !collapsed.isEmpty {
                _WorkspaceRail(regionID: .bottom,
                               document: document,
                               controller: controller)
                    .id("workspace-rail-bottom")
            }
        }
        .layoutRole("workspace-bottom-slot")
        .debugName("workspace-bottom-slot")
    }
}

private struct _WorkspaceRegionView: View {
    let regionID: WorkspaceRegionID
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        let groupViews = visibleGroups(in: regionID, document: document).map { group in
            AnyView(_WorkspaceTabGroupView(group: group,
                                           document: document,
                                           controller: controller,
                                           content: content)
                .id(group.id)
                .flex())
        }
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            groupViews
        }
        .background(.surface)
        .layoutRole("workspace-region")
        .semanticRole("workspace.region.\(regionID.rawValue)")
        .debugName("workspace-region-\(regionID.rawValue)")
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
                content(activeID)
                    .flex()
                    .semanticRole("workspace.panel.content")
                    .debugName("workspace-panel-\(activeID.rawValue)")
            } else {
                EmptyView()
                    .flex()
            }
        }
        .background(.surface)
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
        let regionID = document.regionContaining(groupID: group.id)
        let canCollapse = regionID != .center && group.panels.contains { panelID in
            document.panels[panelID]?.isCollapsible == true
        }
        let tabButtons = group.panels.compactMap { panelID -> AnyView? in
            guard let panel = document.panels[panelID] else { return nil }
            return AnyView(_WorkspaceTabButton(groupID: group.id,
                                               panelID: panelID,
                                               title: panel.title,
                                               isActive: panelID == group.activePanelID,
                                               document: document,
                                               controller: controller)
                .semanticRole("workspace.tab")
                .debugName("workspace-tab-\(panelID.rawValue)"))
        }
        Row(alignment: .center, spacing: 0) {
            tabButtons
            Spacer(minLength: 0)
            if canCollapse {
                IconButton(resource: WorkspaceIcons.collapse,
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
    let document: WorkspaceDocument
    let controller: WorkspaceController

    @State private var isPressed = false
    @State private var isHovered = false

    var body: some View {
        _WorkspaceTabButtonHost(groupID: groupID,
                                panelID: panelID,
                                title: title,
                                isActive: isActive,
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
                                })
    }
}

private struct _WorkspaceTabButtonHost: _PrimitiveView {
    let groupID: WorkspaceTabGroupID
    let panelID: WorkspacePanelID
    let title: String
    let isActive: Bool
    let isPressed: Bool
    let isHovered: Bool
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let onHoverChange: (Bool) -> Void
    let onDown: () -> Void
    let onCancelPress: () -> Void
    let onClick: () -> Void
    let onDrop: (WorkspaceTarget) -> Void

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
        registry.setPointer(node, route: .dockDrag) { event, phase, _ in
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
                if PointerCaptureHolder.current?.target === node {
                    PointerCaptureHolder.current?.release()
                }
                guard let state else { return .ignored }
                if state.didDrag {
                    if let target = resolveWorkspaceDropTarget(x: event.x,
                                                               y: event.y,
                                                               sourceGroupID: groupID,
                                                               sourcePanelID: panelID,
                                                               document: document,
                                                               from: node) {
                        drop(target)
                    } else {
                        cancelPress()
                    }
                    return .handled
                }
                click()
                return .handled
            }
        }
        registry.setMotion(node, route: .dockDrag) { event, _ in
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
        let style = isActive ? AnyButtonStyle(SecondaryButtonStyle()) : AnyButtonStyle(GhostButtonStyle())
        let config = ButtonStyleConfiguration(label: AnyView(Text(title).font(.label)),
                                              role: .normal,
                                              isPressed: isPressed,
                                              isHovered: isHovered,
                                              isFocused: FocusChainHolder.current?.focused === node,
                                              isEnabled: true,
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

private struct _WorkspaceRail: View {
    let regionID: WorkspaceRegionID
    let document: WorkspaceDocument
    let controller: WorkspaceController

    var body: some View {
        let groups = collapsedGroups(in: regionID, document: document)
        let railButtons = groups.flatMap { group in
            railItems(group: group, document: document).map { item in
                AnyView(_WorkspaceRailButton(regionID: regionID,
                                             groupID: group.id,
                                             title: item.title,
                                             controller: controller)
                    .id("workspace-restore-\(regionID.rawValue)-\(group.id.rawValue)-\(item.panelID.rawValue)"))
            }
        }
        if groups.isEmpty {
            EmptyView()
        } else if regionID == .bottom {
            Row(alignment: .center, spacing: 6) {
                railButtons
            }
            .padding(horizontal: 4, vertical: 4)
            .background(.surfaceSunken)
            .frame(height: 40)
            .layoutRole("workspace-rail")
            .semanticRole("workspace.rail.bottom")
            .debugName("workspace-rail-bottom")
        } else {
            Box(direction: .column, alignItems: .center, spacing: 4) {
                railButtons
            }
            .padding(horizontal: 4, vertical: 6)
            .background(.surfaceVariant)
            .frame(width: 40)
            .layoutRole("workspace-rail")
            .semanticRole("workspace.rail.\(regionID.rawValue)")
            .debugName("workspace-rail-\(regionID.rawValue)")
        }
    }
}

private struct _WorkspaceRailButton: View {
    let regionID: WorkspaceRegionID
    let groupID: WorkspaceTabGroupID
    let title: String
    let controller: WorkspaceController

    var body: some View {
        if regionID == .bottom {
            Button(tooltip: title) {
                _ = controller.dispatch(.expand(groupID))
            } label: {
                Row(alignment: .center, spacing: 6) {
                    Image(resource: WorkspaceIcons.expandDown,
                          width: 10,
                          height: 10,
                          tint: .white,
                          contentMode: .fit,
                          renderingMode: .alphaMask)
                    Text(title)
                        .font(.label)
                }
                .padding(horizontal: 8, vertical: 4)
            }
            .buttonStyle(.secondary)
            .semanticRole("workspace.rail.restore")
            .debugName("workspace-restore-\(groupID.rawValue)")
        } else {
            Button(tooltip: title) {
                _ = controller.dispatch(.expand(groupID))
            } label: {
                _WorkspaceVerticalTitle(title: title)
            }
            .buttonStyle(_WorkspaceSideRailButtonStyle())
            .semanticRole("workspace.rail.restore")
            .debugName("workspace-restore-\(groupID.rawValue)")
        }
    }
}

private struct _WorkspaceSideRailButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let bg: Color = {
            if !configuration.isEnabled { return theme.colors.surfaceSunken }
            let base = theme.colors.surfaceRaised
            if configuration.isPressed { return base.composited(over: theme.colors.stateLayerPressed) }
            if configuration.isHovered { return base.composited(over: theme.colors.stateLayerHover) }
            return base
        }()
        let border = configuration.isFocused ? theme.colors.focusRing : theme.colors.border
        let borderWidth: Float = configuration.isFocused ? 2 : 1

        return Box(direction: .column,
                   alignItems: .center,
                   justifyContent: .center,
                   spacing: 0) {
            AnyView(configuration.label)
                .font(SemanticFontRef.bodyStrong)
                .foregroundColor(SemanticColorRef.onSurface)
        }
        .frame(width: 32)
        .padding(horizontal: 4, vertical: 0)
        .background(bg)
        .cornerRadius(theme.radius.sm)
        .border(border, width: borderWidth)
        .opacity(configuration.isEnabled ? 1 : 0.55)
        .animation(.semantic(.snappy, in: theme), value: configuration.interactionKey)
    }
}

private struct _WorkspaceVerticalTitle: View {
    let title: String

    var body: some View {
        let glyphs = characters.map { char in
            AnyView(Text(char)
                .font(Font.system(size: 11, weight: .medium))
                .lineHeight(12)
                .frame(width: 24, height: 12))
        }
        Box(direction: .column, alignItems: .center, justifyContent: .center, spacing: 1) {
            glyphs
        }
        .frame(width: 24, minHeight: max(72, Float(characters.count) * 13 + 16))
    }

    private var characters: [String] {
        let clean = title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean.isEmpty ? "Panel" : clean).map { String($0) }
    }
}

private struct RailItem {
    var panelID: WorkspacePanelID
    var title: String
}

private func visibleGroups(in regionID: WorkspaceRegionID,
                           document: WorkspaceDocument) -> [WorkspaceTabGroup] {
    document.region(regionID).groupIDs
        .compactMap { document.groups[$0] }
        .filter { !$0.isCollapsed }
}

private func collapsedGroups(in regionID: WorkspaceRegionID,
                             document: WorkspaceDocument) -> [WorkspaceTabGroup] {
    document.region(regionID).groupIDs
        .compactMap { document.groups[$0] }
        .filter(\.isCollapsed)
}

private func railItems(group: WorkspaceTabGroup,
                       document: WorkspaceDocument) -> [RailItem] {
    group.panels.compactMap { panelID in
        guard let panel = document.panels[panelID] else { return nil }
        return RailItem(panelID: panelID, title: panel.title)
    }
}

private func resolveWorkspaceDropTarget(x: Float,
                                        y: Float,
                                        sourceGroupID: WorkspaceTabGroupID,
                                        sourcePanelID: WorkspacePanelID,
                                        document: WorkspaceDocument,
                                        from node: Node) -> WorkspaceTarget? {
    guard let root = workspaceRoot(from: node) else { return nil }
    let point = CGPoint(x: CGFloat(x), y: CGFloat(y))

    let visibleGroupIDs = document.regions.flatMap { region in
        region.groupIDs.filter { document.groups[$0]?.isCollapsed == false }
    }
    for groupID in visibleGroupIDs {
        guard let groupNode = firstNode(rootedAt: root,
                                        debugName: "workspace-group-\(groupID.rawValue)") else {
            continue
        }
        let frame = absoluteFrame(of: groupNode)
        guard frame.contains(point) else { continue }
        guard let regionID = document.regionContaining(groupID: groupID) else { continue }
        let zone = dropZone(in: frame, point: point)
        if groupID == sourceGroupID, zone == .tabGroup {
            return WorkspaceTarget(region: regionID, groupID: groupID, zone: .tabGroup)
        }
        return WorkspaceTarget(region: regionID, groupID: groupID, zone: zone)
    }

    for regionID in WorkspaceRegionID.allCases {
        guard regionID != .center || document.panels[sourcePanelID]?.isDraggable != false,
              let regionNode = firstNode(rootedAt: root,
                                         debugName: "workspace-region-\(regionID.rawValue)") else {
            continue
        }
        let frame = absoluteFrame(of: regionNode)
        guard frame.contains(point) else { continue }
        let targetGroup = visibleGroups(in: regionID, document: document).first?.id
        return WorkspaceTarget(region: regionID, groupID: targetGroup, zone: .region)
    }

    return nil
}

private func dropZone(in frame: CGRect, point: CGPoint) -> WorkspaceDropZone {
    let localX = Float((point.x - frame.minX) / max(frame.width, 1))
    let localY = Float((point.y - frame.minY) / max(frame.height, 1))
    let edge: Float = 0.24
    if localX < edge { return .left }
    if localX > 1 - edge { return .right }
    if localY < edge { return .top }
    if localY > 1 - edge { return .bottom }
    return .tabGroup
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
    var frame = node.frame
    var cursor = node.parent
    while let current = cursor {
        frame.origin.x += current.frame.origin.x
        frame.origin.y += current.frame.origin.y
        cursor = current.parent
    }
    return frame
}

private enum WorkspaceIcons {
    static let collapse = BundleImageResource.svg(named: "collapse",
                                                  in: .module,
                                                  subdirectory: "WorkspaceIcons")
    static let expandRight = BundleImageResource.svg(named: "expand-right",
                                                     in: .module,
                                                     subdirectory: "WorkspaceIcons")
    static let expandDown = BundleImageResource.svg(named: "expand-down",
                                                    in: .module,
                                                    subdirectory: "WorkspaceIcons")
}
