import GuavaUICompose

/// Semantic top-level workspace shell for tool-style applications.
///
/// The shell is fixed to four regions: leading sidebar, center workspace,
/// trailing sidebar, and bottom panel. Dock still owns tabbing and local
/// splits inside a region, but cross-region moves are canonicalised back
/// into this shell so hosts do not end up with arbitrary tree shapes.
public struct PanelWorkspaceLayoutSemantics: Sendable {
    public var leadingFraction: Float
    public var mainFraction: Float
    public var bottomFraction: Float

    public init(leadingFraction: Float = 0.22,
                mainFraction: Float = 0.78,
                bottomFraction: Float = 0.72) {
        self.leadingFraction = leadingFraction
        self.mainFraction = mainFraction
        self.bottomFraction = bottomFraction
    }

    public static var ide: Self { Self() }

    public func install(on controller: DockController, registry: PanelRegistry) {
        let state = LayoutState(leadingFraction: leadingFraction,
                                mainFraction: mainFraction,
                                bottomFraction: bottomFraction)
        // Preserve the controller's current split ratios when the semantics
        // layer is re-installed (e.g. parent view re-init).
        state.captureFractionsIfCanonical(from: controller.root, registry: registry)
        controller.onAllowDrop = { [registry, weak controller] request in
            guard let controller else { return true }
            return Self.allowsDrop(request,
                                   controller: controller,
                                   registry: registry)
        }
        controller.onResolveMinimizedEdge = { [registry, weak controller] leafID in
            guard let controller,
                  let region = Self.regionOfLeaf(id: leafID,
                                                  in: controller.root,
                                                  registry: registry) else {
                return nil
            }
            switch region {
            case .leadingSidebar:
                return .left
            case .trailingSidebar:
                return .right
            case .bottomPanel:
                return .bottom
            case .center:
                return nil
            }
        }
        controller.layoutNormalizer = { [registry] root in
            state.captureFractionsIfCanonical(from: root, registry: registry)
            state.captureLeafIDs(from: root, registry: registry)
            return Self.normalize(root: root,
                                  registry: registry,
                                  state: state)
        }

        state.captureLeafIDs(from: controller.root, registry: registry)
        let normalized = Self.normalize(root: controller.root,
                                        registry: registry,
                                        state: state)
        guard normalized != controller.root else { return }
        controller.replace(root: normalized,
                           satellites: controller.satellites,
                           satelliteOrder: controller.satelliteOrder)
    }

    private struct Fractions {
        var leading: Float
        var main: Float
        var bottom: Float
    }

    private final class LayoutState {
        var fractions: Fractions
        private var regionLeafIDs: [PanelWorkspaceRegion: DockNodeID] = [:]

        init(leadingFraction: Float,
             mainFraction: Float,
             bottomFraction: Float) {
            self.fractions = Fractions(leading: leadingFraction,
                                       main: mainFraction,
                                       bottom: bottomFraction)
        }

        func captureFractionsIfCanonical(from root: DockLayoutNode,
                                         registry: PanelRegistry) {
            guard let captured = PanelWorkspaceLayoutSemantics.captureFractions(from: root,
                                                                                registry: registry) else {
                return
            }
            fractions = captured
        }

        func captureLeafIDs(from root: DockLayoutNode,
                            registry: PanelRegistry) {
            let collected = PanelWorkspaceLayoutSemantics.collectRegions(from: root, registry: registry)
            let candidates = collected.resolvedLeafIDs()
            for region in [PanelWorkspaceRegion.leadingSidebar,
                           .center,
                           .trailingSidebar,
                           .bottomPanel] {
                if regionLeafIDs[region] == nil,
                   let candidate = candidates[region] ?? nil {
                    regionLeafIDs[region] = candidate
                }
            }
        }

        func leafID(for region: PanelWorkspaceRegion,
                    candidate: DockNodeID?) -> DockNodeID {
            if let id = regionLeafIDs[region] {
                return id
            }
            let resolved = candidate ?? DockNodeID()
            regionLeafIDs[region] = resolved
            return resolved
        }
    }

    private struct RegionTabs {
        var tabs: [DockTab] = []
        var activeTabID: DockTabID?
        var candidateLeafIDs: [DockNodeID] = []
    }

    private struct CollectedRegions {
        var leading = RegionTabs()
        var center = RegionTabs()
        var trailing = RegionTabs()
        var bottom = RegionTabs()

        var hasAnyTabs: Bool {
            !leading.tabs.isEmpty
                || !center.tabs.isEmpty
                || !trailing.tabs.isEmpty
                || !bottom.tabs.isEmpty
        }

        func resolvedLeafIDs() -> [PanelWorkspaceRegion: DockNodeID?] {
            var candidates: [PanelWorkspaceRegion: DockNodeID] = [:]
            if leading.candidateLeafIDs.count == 1 { candidates[.leadingSidebar] = leading.candidateLeafIDs[0] }
            if center.candidateLeafIDs.count == 1 { candidates[.center] = center.candidateLeafIDs[0] }
            if trailing.candidateLeafIDs.count == 1 { candidates[.trailingSidebar] = trailing.candidateLeafIDs[0] }
            if bottom.candidateLeafIDs.count == 1 { candidates[.bottomPanel] = bottom.candidateLeafIDs[0] }

            var counts: [DockNodeID: Int] = [:]
            for id in candidates.values {
                counts[id, default: 0] += 1
            }

            var resolved: [PanelWorkspaceRegion: DockNodeID?] = [:]
            for (region, id) in candidates {
                resolved[region] = counts[id] == 1 ? id : nil
            }
            return resolved
        }
    }

     private static func normalize(root: DockLayoutNode,
                                             registry: PanelRegistry,
                                             state: LayoutState) -> DockLayoutNode {
        let collected = collectRegions(from: root, registry: registry)
        guard collected.hasAnyTabs else { return root }
        let leafIDs = collected.resolvedLeafIDs()

          let centerNode = regionNode(id: state.leafID(for: .center,
                                                                      candidate: leafIDs[.center] ?? nil),
                        tabs: collected.center.tabs,
                        activeTabID: collected.center.activeTabID,
                        allowEmpty: true) ?? .empty()

        var mainNode = centerNode
        if !collected.bottom.tabs.isEmpty,
              let bottomNode = regionNode(id: state.leafID(for: .bottomPanel,
                                                                          candidate: leafIDs[.bottomPanel] ?? nil),
                                       tabs: collected.bottom.tabs,
                                       activeTabID: collected.bottom.activeTabID,
                                       allowEmpty: false) {
                mainNode = .vsplit(fraction: state.fractions.bottom,
                               first: centerNode,
                               second: bottomNode)
        }

        var workspaceNode = mainNode
        if !collected.trailing.tabs.isEmpty,
              let trailingNode = regionNode(id: state.leafID(for: .trailingSidebar,
                                                                             candidate: leafIDs[.trailingSidebar] ?? nil),
                                         tabs: collected.trailing.tabs,
                                         activeTabID: collected.trailing.activeTabID,
                                         allowEmpty: false) {
                workspaceNode = .hsplit(fraction: state.fractions.main,
                                    first: mainNode,
                                    second: trailingNode)
        }

        if !collected.leading.tabs.isEmpty,
              let leadingNode = regionNode(id: state.leafID(for: .leadingSidebar,
                                                                            candidate: leafIDs[.leadingSidebar] ?? nil),
                                        tabs: collected.leading.tabs,
                                        activeTabID: collected.leading.activeTabID,
                                        allowEmpty: false) {
                return .hsplit(fraction: state.fractions.leading,
                           first: leadingNode,
                           second: workspaceNode)
        }
        return workspaceNode
    }

    private static func collectRegions(from node: DockLayoutNode,
                                       registry: PanelRegistry) -> CollectedRegions {
        var collected = CollectedRegions()
        collectRegions(from: node, registry: registry, into: &collected)
        return collected
    }

    private static func collectRegions(from node: DockLayoutNode,
                                       registry: PanelRegistry,
                                       into collected: inout CollectedRegions) {
        switch node {
        case .empty:
            return
        case .tabs(let id, let tabs, let activeTabID):
            var regionsInLeaf: Set<PanelWorkspaceRegion> = []
            for tab in tabs {
                let region = registry.descriptor(for: tab.userKey)?.preferredRegion ?? .center
                regionsInLeaf.insert(region)
                switch region {
                case .leadingSidebar:
                    collected.leading.tabs.append(tab)
                    if activeTabID == tab.id { collected.leading.activeTabID = tab.id }
                case .center:
                    collected.center.tabs.append(tab)
                    if activeTabID == tab.id { collected.center.activeTabID = tab.id }
                case .trailingSidebar:
                    collected.trailing.tabs.append(tab)
                    if activeTabID == tab.id { collected.trailing.activeTabID = tab.id }
                case .bottomPanel:
                    collected.bottom.tabs.append(tab)
                    if activeTabID == tab.id { collected.bottom.activeTabID = tab.id }
                }
            }
            for region in regionsInLeaf {
                switch region {
                case .leadingSidebar:
                    collected.leading.candidateLeafIDs.append(id)
                case .center:
                    collected.center.candidateLeafIDs.append(id)
                case .trailingSidebar:
                    collected.trailing.candidateLeafIDs.append(id)
                case .bottomPanel:
                    collected.bottom.candidateLeafIDs.append(id)
                }
            }
        case .split(_, _, _, let first, let second):
            collectRegions(from: first, registry: registry, into: &collected)
            collectRegions(from: second, registry: registry, into: &collected)
        }
    }

    private static func regionNode(id: DockNodeID?,
                                   tabs: [DockTab],
                                   activeTabID: DockTabID?,
                                   allowEmpty: Bool) -> DockLayoutNode? {
        if tabs.isEmpty {
            return allowEmpty ? .empty(id: id ?? DockNodeID()) : nil
        }
        return .tabs(id: id ?? DockNodeID(),
                     tabs: tabs,
                     activeTabID: activeTabID ?? tabs.first?.id)
    }

    private static func captureFractions(from root: DockLayoutNode,
                                         registry: PanelRegistry) -> Fractions? {
        let collected = collectRegions(from: root, registry: registry)
        guard collected.hasAnyTabs else { return nil }

        let wantsLeading = !collected.leading.tabs.isEmpty
        let wantsTrailing = !collected.trailing.tabs.isEmpty
        let wantsBottom = !collected.bottom.tabs.isEmpty
        let allowEmptyCenter = true

        var fractions = Fractions(leading: 0.22, main: 0.78, bottom: 0.72)
        let workspaceRoot: DockLayoutNode

        if wantsLeading {
            guard case .split(_, .horizontal, let leadingFraction, let leadingNode, let remainder) = root,
                  matchesRegionLeaf(leadingNode,
                                    region: .leadingSidebar,
                                    registry: registry,
                                    allowEmpty: false) else {
                return nil
            }
            fractions.leading = leadingFraction
            workspaceRoot = remainder
        } else {
            workspaceRoot = root
        }

        let mainRoot: DockLayoutNode
        if wantsTrailing {
            guard case .split(_, .horizontal, let mainFraction, let mainNode, let trailingNode) = workspaceRoot,
                  matchesRegionLeaf(trailingNode,
                                    region: .trailingSidebar,
                                    registry: registry,
                                    allowEmpty: false) else {
                return nil
            }
            fractions.main = mainFraction
            mainRoot = mainNode
        } else {
            mainRoot = workspaceRoot
        }

        if wantsBottom {
            guard case .split(_, .vertical, let bottomFraction, let centerNode, let bottomNode) = mainRoot,
                  matchesRegionLeaf(centerNode,
                                    region: .center,
                                    registry: registry,
                                    allowEmpty: allowEmptyCenter),
                  matchesRegionLeaf(bottomNode,
                                    region: .bottomPanel,
                                    registry: registry,
                                    allowEmpty: false) else {
                return nil
            }
            fractions.bottom = bottomFraction
            return fractions
        }

        guard matchesRegionLeaf(mainRoot,
                                region: .center,
                                registry: registry,
                                allowEmpty: allowEmptyCenter) else {
            return nil
        }
        return fractions
    }

    private static func matchesRegionLeaf(_ node: DockLayoutNode,
                                          region: PanelWorkspaceRegion,
                                          registry: PanelRegistry,
                                          allowEmpty: Bool) -> Bool {
        switch node {
        case .empty:
            return allowEmpty
        case .tabs(_, let tabs, _):
            guard !tabs.isEmpty else { return allowEmpty }
            return tabs.allSatisfy {
                (registry.descriptor(for: $0.userKey)?.preferredRegion ?? .center) == region
            }
        case .split:
            return false
        }
    }

    private static func allowsDrop(_ request: DockDropRequest,
                                   controller: DockController,
                                   registry: PanelRegistry) -> Bool {
        guard let sourceRegion = sourceRegion(for: request, controller: controller, registry: registry),
              let targetRegion = targetRegion(for: request.target, controller: controller, registry: registry) else {
            return true
        }

        guard sourceRegion == targetRegion else { return false }

        if sourceRegion == .center {
            return true
        }

        switch request.target {
        case .splitEdge:
            return false
        case .tabSlot, .replace:
            return true
        }
    }

    private static func sourceRegion(for request: DockDropRequest,
                                     controller: DockController,
                                     registry: PanelRegistry) -> PanelWorkspaceRegion? {
        if let tabID = request.tabID,
           let region = regionOfTab(id: tabID, in: controller.root, registry: registry) {
            return region
        }
        switch request.origin {
        case .mainTreeLeaf(let leafID), .satellite(let leafID):
            return regionOfLeaf(id: leafID, in: controller.root, registry: registry)
        case .mainTreeTab:
            return nil
        }
    }

    private static func targetRegion(for target: DockDropTarget,
                                     controller: DockController,
                                     registry: PanelRegistry) -> PanelWorkspaceRegion? {
        let nodeID: DockNodeID
        switch target {
        case .tabSlot(let parent, _):
            nodeID = parent
        case .replace(let target), .splitEdge(let target, _):
            nodeID = target
        }
        return regionOfLeaf(id: nodeID, in: controller.root, registry: registry)
    }

    private static func regionOfTab(id: DockTabID,
                                    in node: DockLayoutNode,
                                    registry: PanelRegistry) -> PanelWorkspaceRegion? {
        switch node {
        case .empty:
            return nil
        case .tabs(_, let tabs, _):
            guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
            return registry.descriptor(for: tab.userKey)?.preferredRegion ?? .center
        case .split(_, _, _, let first, let second):
            return regionOfTab(id: id, in: first, registry: registry)
                ?? regionOfTab(id: id, in: second, registry: registry)
        }
    }

    private static func regionOfLeaf(id: DockNodeID,
                                     in node: DockLayoutNode,
                                     registry: PanelRegistry) -> PanelWorkspaceRegion? {
        guard let found = node.find(id) else { return nil }
        switch found {
        case .empty:
            return .center
        case .tabs(_, let tabs, _):
            guard let first = tabs.first else { return .center }
            return registry.descriptor(for: first.userKey)?.preferredRegion ?? .center
        case .split:
            return nil
        }
    }
}
