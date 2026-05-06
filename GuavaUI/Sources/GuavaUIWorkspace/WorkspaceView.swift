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
            if panelID == group.activePanelID {
                return AnyView(Button(tooltip: panel.title) {
                    _ = controller.dispatch(.setActivePanel(groupID: group.id, panelID: panelID))
                } label: {
                    Text(panel.title)
                        .font(.label)
                }
                .buttonStyle(.secondary)
                .semanticRole("workspace.tab")
                .debugName("workspace-tab-\(panelID.rawValue)"))
            }
            return AnyView(Button(tooltip: panel.title) {
                _ = controller.dispatch(.setActivePanel(groupID: group.id, panelID: panelID))
            } label: {
                Text(panel.title)
                    .font(.label)
            }
            .buttonStyle(.ghost)
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
        .frame(width: 32, minHeight: max(72, Float(characters.count) * 13 + 16))
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
