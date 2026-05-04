import GuavaUICompose

/// Semantic top-level workspace shell for tool-style applications.
///
/// The shell is fixed to four regions: leading sidebar, center workspace,
/// trailing sidebar, and bottom panel. Dock still owns tabbing and local
/// splits inside a region, but cross-region moves are canonicalised back
/// into this shell so hosts do not end up with arbitrary tree shapes.
public struct PanelWorkspaceLayoutSemantics: Sendable {
    private static let regionOverridesStorageKey = "GuavaUIApp.PanelWorkspaceLayoutSemantics.regionOverrides"

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
        state.regionOverrides = Self.decodeRegionOverrides(controller.semanticStorage[Self.regionOverridesStorageKey] ?? [:])
        // Preserve the controller's current split ratios when the semantics
        // layer is re-installed (e.g. parent view re-init).
        state.captureFractionsIfCanonical(from: controller.root, registry: registry)
        controller.onAllowDrop = { [registry, weak controller] request in
            guard let controller else { return true }
            return Self.allowsDrop(request,
                                   controller: controller,
                                   registry: registry,
                                   state: state)
        }
        controller.onCommitDrop = { [registry, weak controller] request in
            guard let controller else { return }
            Self.commitDrop(request,
                            controller: controller,
                            registry: registry,
                            state: state)
        }
        controller.onDidCommitDrop = { [registry, weak controller] request in
            guard let controller else { return }
            Self.didCommitDrop(request,
                               controller: controller,
                               registry: registry,
                               state: state)
        }
        controller.onResolveMinimizedEdge = { [registry, weak controller] leafID in
            guard let controller,
                  let region = Self.regionOfLeaf(id: leafID,
                                                  in: controller.root,
                                                  registry: registry,
                                                  state: state) else {
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
        controller.layoutNormalizer = { [registry, weak controller] root in
            let minimizedIDs = Set(controller.map { Array($0.minimizedLeaves.keys) } ?? [])
            if !Self.containsAnyLeaf(in: root, ids: minimizedIDs) {
                state.captureFractionsIfCanonical(from: root, registry: registry)
            }
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
                           satelliteOrder: controller.satelliteOrder,
                           minimizedLeaves: controller.minimizedLeaves,
                           minimizedOrder: controller.minimizedOrder)
    }

    private struct Fractions {
        var leading: Float
        var main: Float
        var bottom: Float
    }

    private struct CapturedFractions {
        var leading: Float?
        var main: Float?
        var bottom: Float?
    }

    private final class LayoutState {
        var fractions: Fractions
        private var regionLeafIDs: [PanelWorkspaceRegion: DockNodeID] = [:]
        var regionOverrides: [String: PanelWorkspaceRegion] = [:]

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
                                                                                registry: registry,
                                                                                state: self) else {
                return
            }
            if let leading = captured.leading {
                fractions.leading = leading
            }
            if let main = captured.main {
                fractions.main = main
            }
            if let bottom = captured.bottom {
                fractions.bottom = bottom
            }
        }

        func captureLeafIDs(from root: DockLayoutNode,
                            registry: PanelRegistry) {
            let collected = PanelWorkspaceLayoutSemantics.collectRegions(from: root,
                                                                         registry: registry,
                                                                         state: self)
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

        func region(for tab: DockTab,
                    registry: PanelRegistry) -> PanelWorkspaceRegion {
            regionOverrides[tab.userKey]
                ?? registry.descriptor(for: tab.userKey)?.preferredRegion
                ?? .center
        }

        func setRegion(_ region: PanelWorkspaceRegion,
                       forUserKey userKey: String,
                       registry: PanelRegistry) {
            let preferred = registry.descriptor(for: userKey)?.preferredRegion ?? .center
            if preferred == region {
                regionOverrides.removeValue(forKey: userKey)
            } else {
                regionOverrides[userKey] = region
            }
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
        let collected = collectRegions(from: root, registry: registry, state: state)
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
                                       registry: PanelRegistry,
                                       state: LayoutState? = nil) -> CollectedRegions {
        var collected = CollectedRegions()
        collectRegions(from: node, registry: registry, state: state, into: &collected)
        return collected
    }

    private static func collectRegions(from node: DockLayoutNode,
                                       registry: PanelRegistry,
                                       state: LayoutState?,
                                       into collected: inout CollectedRegions) {
        switch node {
        case .empty:
            return
        case .tabs(let id, let tabs, let activeTabID):
            var regionsInLeaf: Set<PanelWorkspaceRegion> = []
            for tab in tabs {
                let region = state?.region(for: tab, registry: registry)
                    ?? registry.descriptor(for: tab.userKey)?.preferredRegion
                    ?? .center
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
            collectRegions(from: first, registry: registry, state: state, into: &collected)
            collectRegions(from: second, registry: registry, state: state, into: &collected)
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
                                         registry: PanelRegistry,
                                         state: LayoutState? = nil) -> CapturedFractions? {
        let collected = collectRegions(from: root, registry: registry, state: state)
        guard collected.hasAnyTabs else { return nil }

        let wantsLeading = !collected.leading.tabs.isEmpty
        let wantsTrailing = !collected.trailing.tabs.isEmpty
        let wantsBottom = !collected.bottom.tabs.isEmpty
        let allowEmptyCenter = true

        var fractions = CapturedFractions()
        let workspaceRoot: DockLayoutNode

        if wantsLeading {
            guard case .split(_, .horizontal, let leadingFraction, let leadingNode, let remainder) = root,
                  matchesRegionLeaf(leadingNode,
                                    region: .leadingSidebar,
                                    registry: registry,
                                    state: state,
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
                                    state: state,
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
                                    state: state,
                                    allowEmpty: allowEmptyCenter),
                  matchesRegionLeaf(bottomNode,
                                    region: .bottomPanel,
                                    registry: registry,
                                    state: state,
                                    allowEmpty: false) else {
                return nil
            }
            fractions.bottom = bottomFraction
            return fractions
        }

        guard matchesRegionLeaf(mainRoot,
                                region: .center,
                                registry: registry,
                                state: state,
                                allowEmpty: allowEmptyCenter) else {
            return nil
        }
        return fractions
    }

    private static func matchesRegionLeaf(_ node: DockLayoutNode,
                                          region: PanelWorkspaceRegion,
                                          registry: PanelRegistry,
                                          state: LayoutState? = nil,
                                          allowEmpty: Bool) -> Bool {
        switch node {
        case .empty:
            return allowEmpty
        case .tabs(_, let tabs, _):
            guard !tabs.isEmpty else { return allowEmpty }
            return tabs.allSatisfy {
                (state?.region(for: $0, registry: registry)
                    ?? registry.descriptor(for: $0.userKey)?.preferredRegion
                    ?? .center) == region
            }
        case .split:
            return false
        }
    }

    private static func containsAnyLeaf(in node: DockLayoutNode,
                                        ids: Set<DockNodeID>) -> Bool {
        guard !ids.isEmpty else { return false }
        switch node {
        case .empty:
            return false
        case .tabs(let id, _, _):
            return ids.contains(id)
        case .split(_, _, _, let first, let second):
            return containsAnyLeaf(in: first, ids: ids)
                || containsAnyLeaf(in: second, ids: ids)
        }
    }

    private static func allowsDrop(_ request: DockDropRequest,
                                   controller: DockController,
                                   registry: PanelRegistry,
                                   state: LayoutState) -> Bool {
        _ = sourceRegion(for: request, controller: controller, registry: registry, state: state)
        _ = targetRegion(for: request.target, controller: controller, registry: registry, state: state)
        return true
    }

    private static func commitDrop(_ request: DockDropRequest,
                                   controller: DockController,
                                   registry: PanelRegistry,
                                   state: LayoutState) {
        guard let targetRegion = targetRegion(for: request.target,
                                              controller: controller,
                                              registry: registry,
                                              state: state) else {
            return
        }
        for userKey in userKeys(for: request, controller: controller) {
            state.setRegion(targetRegion, forUserKey: userKey, registry: registry)
        }
        controller.semanticStorage[regionOverridesStorageKey] = encodeRegionOverrides(state.regionOverrides)
    }

    private static func didCommitDrop(_ request: DockDropRequest,
                                      controller: DockController,
                                      registry: PanelRegistry,
                                      state: LayoutState) {
        guard let targetRegion = targetRegion(for: request.target,
                                              controller: controller,
                                              registry: registry,
                                              state: state),
              targetRegion != .center else {
            return
        }
        let restoreIDs = controller.minimizedOrder.filter { leafID in
            guard let minimized = controller.minimizedLeaves[leafID] else { return false }
            return regionOfMinimizedLeaf(minimized,
                                         registry: registry,
                                         state: state) == targetRegion
        }
        for leafID in restoreIDs {
            controller.restoreMinimizedLeaf(leafID)
        }
    }

    private static func decodeRegionOverrides(_ raw: [String: String]) -> [String: PanelWorkspaceRegion] {
        var decoded: [String: PanelWorkspaceRegion] = [:]
        for (userKey, value) in raw {
            if let region = PanelWorkspaceRegion(rawValue: value) {
                decoded[userKey] = region
            }
        }
        return decoded
    }

    private static func encodeRegionOverrides(_ overrides: [String: PanelWorkspaceRegion]) -> [String: String] {
        overrides.mapValues(\.rawValue)
    }

    private static func sourceRegion(for request: DockDropRequest,
                                     controller: DockController,
                                     registry: PanelRegistry,
                                     state: LayoutState) -> PanelWorkspaceRegion? {
        if let tabID = request.tabID,
           let region = regionOfTab(id: tabID, in: controller.root, registry: registry, state: state) {
            return region
        }
        switch request.origin {
        case .mainTreeLeaf(let leafID), .satellite(let leafID):
            return regionOfLeaf(id: leafID, in: controller.root, registry: registry, state: state)
        case .mainTreeTab:
            return nil
        }
    }

    private static func targetRegion(for target: DockDropTarget,
                                     controller: DockController,
                                     registry: PanelRegistry,
                                     state: LayoutState) -> PanelWorkspaceRegion? {
        let nodeID: DockNodeID
        switch target {
        case .tabSlot(let parent, _):
            nodeID = parent
        case .replace(let target), .splitEdge(let target, _):
            nodeID = target
        }
        if let region = regionOfLeaf(id: nodeID, in: controller.root, registry: registry, state: state) {
            return region
        }
        if case .splitEdge(_, let edge) = target {
            return region(forGlobalEdge: edge)
        }
        return nil
    }

    private static func region(forGlobalEdge edge: DockEdge) -> PanelWorkspaceRegion? {
        switch edge {
        case .left:
            return .leadingSidebar
        case .right:
            return .trailingSidebar
        case .bottom:
            return .bottomPanel
        case .top, .center:
            return .center
        }
    }

    private static func regionOfTab(id: DockTabID,
                                    in node: DockLayoutNode,
                                    registry: PanelRegistry,
                                    state: LayoutState) -> PanelWorkspaceRegion? {
        switch node {
        case .empty:
            return nil
        case .tabs(_, let tabs, _):
            guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
            return state.region(for: tab, registry: registry)
        case .split(_, _, _, let first, let second):
            return regionOfTab(id: id, in: first, registry: registry, state: state)
                ?? regionOfTab(id: id, in: second, registry: registry, state: state)
        }
    }

    private static func regionOfLeaf(id: DockNodeID,
                                     in node: DockLayoutNode,
                                     registry: PanelRegistry,
                                     state: LayoutState) -> PanelWorkspaceRegion? {
        guard let found = node.find(id) else { return nil }
        switch found {
        case .empty:
            return .center
        case .tabs(_, let tabs, _):
            guard !tabs.isEmpty else { return .center }
            // Use majority vote across all tabs, falling back to the first
            // tab's region. This prevents a single stray tab from
            // misidentifying the leaf's region (e.g. right after a drag-drop
            // before the normalizer has canonicalised).
            var counts: [PanelWorkspaceRegion: Int] = [:]
            for tab in tabs {
                let region = state.region(for: tab, registry: registry)
                counts[region, default: 0] += 1
            }
            return counts.max(by: { $0.value < $1.value })?.key
                ?? state.region(for: tabs[0], registry: registry)
        case .split:
            return nil
        }
    }

    private static func regionOfMinimizedLeaf(_ leaf: DockMinimizedLeaf,
                                              registry: PanelRegistry,
                                              state: LayoutState) -> PanelWorkspaceRegion? {
        switch leaf.node {
        case .tabs(_, let tabs, _):
            guard let first = tabs.first else { return .center }
            return state.region(for: first, registry: registry)
        case .empty:
            return .center
        case .split:
            return nil
        }
    }

    private static func userKeys(for request: DockDropRequest,
                                 controller: DockController) -> [String] {
        if let tabID = request.tabID,
           let tab = tab(id: tabID, in: controller.root) {
            return [tab.userKey]
        }
        guard let sourceLeafID = request.sourceLeafID else { return [] }
        switch request.origin {
        case .mainTreeTab:
            return []
        case .mainTreeLeaf:
            return userKeys(inLeaf: sourceLeafID, root: controller.root)
        case .satellite:
            if let satellite = controller.satellites[sourceLeafID] {
                return userKeys(inLeaf: sourceLeafID, root: satellite)
            }
            return []
        }
    }

    private static func tab(id: DockTabID,
                            in node: DockLayoutNode) -> DockTab? {
        switch node {
        case .empty:
            return nil
        case .tabs(_, let tabs, _):
            return tabs.first { $0.id == id }
        case .split(_, _, _, let first, let second):
            return tab(id: id, in: first) ?? tab(id: id, in: second)
        }
    }

    private static func userKeys(inLeaf leafID: DockNodeID,
                                 root: DockLayoutNode) -> [String] {
        guard let node = root.find(leafID) else { return [] }
        switch node {
        case .tabs(_, let tabs, _):
            return tabs.map(\.userKey)
        case .empty, .split:
            return []
        }
    }
}
