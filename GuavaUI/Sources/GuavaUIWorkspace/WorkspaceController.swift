import Foundation

public enum WorkspaceDropZone: Sendable, Codable, Equatable {
    case tabGroup
    case left
    case right
    case top
    case bottom
    case region
}

public struct WorkspaceTarget: Sendable, Codable, Equatable {
    public var region: WorkspaceRegionID
    public var groupID: WorkspaceTabGroupID?
    public var zone: WorkspaceDropZone

    public init(region: WorkspaceRegionID,
                groupID: WorkspaceTabGroupID? = nil,
                zone: WorkspaceDropZone = .tabGroup) {
        self.region = region
        self.groupID = groupID
        self.zone = zone
    }
}

public struct WorkspaceHitTarget: Sendable, Equatable {
    public var region: WorkspaceRegionID
    public var groupID: WorkspaceTabGroupID?
    public var panelID: WorkspacePanelID?
    public var zone: WorkspaceDropZone

    public init(region: WorkspaceRegionID,
                groupID: WorkspaceTabGroupID? = nil,
                panelID: WorkspacePanelID? = nil,
                zone: WorkspaceDropZone) {
        self.region = region
        self.groupID = groupID
        self.panelID = panelID
        self.zone = zone
    }
}

public enum WorkspaceCommand: Sendable, Equatable {
    case replaceDocument(WorkspaceDocument)
    case collapse(WorkspaceTabGroupID)
    case expand(WorkspaceTabGroupID)
    case toggleCollapse(WorkspaceTabGroupID)
    case setActivePanel(groupID: WorkspaceTabGroupID, panelID: WorkspacePanelID)
    case reorderPanel(WorkspacePanelID, in: WorkspaceTabGroupID, toIndex: Int)
    case movePanel(WorkspacePanelID, to: WorkspaceTarget)
    case closePanel(WorkspacePanelID)
    case closeOthers(groupID: WorkspaceTabGroupID, keeping: WorkspacePanelID)
    case closeToTheRight(groupID: WorkspaceTabGroupID, of: WorkspacePanelID)
    case reopenLastClosed
    case setPinned(panelID: WorkspacePanelID, isPinned: Bool)
    case floatGroup(WorkspaceTabGroupID, windowID: WorkspaceFloatingWindowID, frame: WorkspaceRect)
    case redockFloatingWindow(WorkspaceFloatingWindowID, to: WorkspaceTarget)
    case moveFloatingWindow(WorkspaceFloatingWindowID, frame: WorkspaceRect)
    case focusFloatingWindow(WorkspaceFloatingWindowID)
    case resizeSplit(WorkspaceSplitID, fraction: Float)
}

public struct WorkspaceTransactionResult: Sendable, Equatable {
    public var didChange: Bool
    public var changedRegions: Set<WorkspaceRegionID>
    public var focusPanelID: WorkspacePanelID?
    public var persistenceDirty: Bool

    public static let unchanged = WorkspaceTransactionResult(didChange: false,
                                                             changedRegions: [],
                                                             focusPanelID: nil,
                                                             persistenceDirty: false)

    public init(didChange: Bool,
                changedRegions: Set<WorkspaceRegionID>,
                focusPanelID: WorkspacePanelID?,
                persistenceDirty: Bool) {
        self.didChange = didChange
        self.changedRegions = changedRegions
        self.focusPanelID = focusPanelID
        self.persistenceDirty = persistenceDirty
    }
}

public final class WorkspaceController: @unchecked Sendable {
    public struct SubscriptionToken: Hashable, Sendable {
        let raw: UInt64
    }

    public private(set) var document: WorkspaceDocument
    public private(set) var version: UInt64 = 0

    private var subscribers: [SubscriptionToken: (WorkspaceController) -> Void] = [:]
    private var nextSubscriberID: UInt64 = 0

    public init(document: WorkspaceDocument) {
        self.document = document
    }

    public func subscribe(_ handler: @escaping (WorkspaceController) -> Void) -> SubscriptionToken {
        nextSubscriberID &+= 1
        let token = SubscriptionToken(raw: nextSubscriberID)
        subscribers[token] = handler
        return token
    }

    public func unsubscribe(_ token: SubscriptionToken) {
        subscribers.removeValue(forKey: token)
    }

    @discardableResult
    public func dispatch(_ command: WorkspaceCommand) -> WorkspaceTransactionResult {
        let before = document
        let result = apply(command)
        guard result.didChange || before != document else {
            return .unchanged
        }
        version &+= 1
        notifyChange()
        return result
    }

    public func replace(_ document: WorkspaceDocument) {
        _ = dispatch(.replaceDocument(document))
    }

    private func apply(_ command: WorkspaceCommand) -> WorkspaceTransactionResult {
        switch command {
        case .replaceDocument(let next):
            guard document != next else { return .unchanged }
            document = next
            return WorkspaceTransactionResult(didChange: true,
                                              changedRegions: Set(WorkspaceRegionID.allCases),
                                              focusPanelID: activeCenterPanel(),
                                              persistenceDirty: true)
        case .collapse(let groupID):
            return setCollapsed(groupID, collapsed: true)
        case .expand(let groupID):
            return setCollapsed(groupID, collapsed: false)
        case .toggleCollapse(let groupID):
            guard let group = document.groups[groupID] else { return .unchanged }
            return setCollapsed(groupID, collapsed: !group.isCollapsed)
        case .setActivePanel(let groupID, let panelID):
            guard var group = document.groups[groupID],
                  group.panels.contains(panelID),
                  group.activePanelID != panelID else {
                return .unchanged
            }
            group.activePanelID = panelID
            document.groups[groupID] = group
            return WorkspaceTransactionResult(didChange: true,
                                              changedRegions: [document.regionContaining(groupID: groupID)].compactSet(),
                                              focusPanelID: panelID,
                                              persistenceDirty: true)
        case .reorderPanel(let panelID, let groupID, let index):
            return reorderPanel(panelID, in: groupID, toIndex: index)
        case .movePanel(let panelID, let target):
            return movePanel(panelID, to: target)
        case .closePanel(let panelID):
            return closePanel(panelID)
        case .closeOthers(let groupID, let panelID):
            return closeOthers(groupID: groupID, keeping: panelID)
        case .closeToTheRight(let groupID, let panelID):
            return closeToTheRight(groupID: groupID, of: panelID)
        case .reopenLastClosed:
            return reopenLastClosed()
        case .setPinned(let panelID, let isPinned):
            return setPinned(panelID: panelID, isPinned: isPinned)
        case .floatGroup(let groupID, let windowID, let frame):
            return floatGroup(groupID, windowID: windowID, frame: frame)
        case .redockFloatingWindow(let windowID, let target):
            return redockFloatingWindow(windowID, to: target)
        case .moveFloatingWindow(let windowID, let frame):
            return moveFloatingWindow(windowID, frame: frame)
        case .focusFloatingWindow(let windowID):
            return focusFloatingWindow(windowID)
        case .resizeSplit(let splitID, let fraction):
            return resizeSplit(splitID, fraction: fraction)
        }
    }

    private func setCollapsed(_ groupID: WorkspaceTabGroupID,
                              collapsed: Bool) -> WorkspaceTransactionResult {
        guard var group = document.groups[groupID],
              group.isCollapsed != collapsed else {
            return .unchanged
        }
        guard let regionID = document.regionContaining(groupID: groupID),
              regionID != .center else {
            return .unchanged
        }
        if collapsed {
            let canCollapse = group.panels.contains { panelID in
                document.panels[panelID]?.isCollapsible == true
            }
            guard canCollapse else { return .unchanged }
        }
        group.isCollapsed = collapsed
        document.groups[groupID] = group
        return WorkspaceTransactionResult(didChange: true,
                                          changedRegions: [regionID],
                                          focusPanelID: collapsed ? nil : group.activePanelID,
                                          persistenceDirty: true)
    }

    private func movePanel(_ panelID: WorkspacePanelID,
                           to target: WorkspaceTarget) -> WorkspaceTransactionResult {
        guard document.panels[panelID] != nil else { return .unchanged }
        var changedRegions = Set<WorkspaceRegionID>()
        var sourceGroupID: WorkspaceTabGroupID?
        var sourceRegionID: WorkspaceRegionID?

        if let located = locate(panelID: panelID) {
            sourceGroupID = located.group.id
            sourceRegionID = located.regionID
        }

        if let sourceRegionID {
            changedRegions.insert(sourceRegionID)
        }

        let destination = destination(for: target)
        changedRegions.insert(destination.region)

        if let sourceGroupID,
           sourceGroupID == target.groupID,
           destination.region == sourceRegionID,
           !destination.requiresAdjacentGroup {
            guard var group = document.groups[sourceGroupID] else { return .unchanged }
            let didChange = group.activePanelID != panelID || group.isCollapsed
            group.activePanelID = panelID
            group.isCollapsed = false
            document.groups[group.id] = group
            guard didChange else { return .unchanged }
            return WorkspaceTransactionResult(didChange: true,
                                              changedRegions: changedRegions,
                                              focusPanelID: panelID,
                                              persistenceDirty: true)
        }

        if let sourceGroupID {
            remove(panelID: panelID, from: sourceGroupID)
        }

        let targetGroupID: WorkspaceTabGroupID
        if destination.requiresAdjacentGroup {
            targetGroupID = makeGroup(in: destination.region,
                                      adjacentTo: destination.anchorGroupID,
                                      after: destination.insertAfterAnchor)
        } else if let groupID = destination.anchorGroupID,
                  document.groups[groupID] != nil {
            targetGroupID = groupID
            ensureGroup(groupID, in: destination.region)
        } else {
            targetGroupID = firstGroupID(in: destination.region) ?? makePrimaryGroup(in: destination.region)
        }
        var targetGroup = document.groups[targetGroupID] ?? WorkspaceTabGroup(id: targetGroupID, panels: [])
        if !targetGroup.panels.contains(panelID) {
            insert(panelID: panelID, into: &targetGroup, at: targetGroup.panels.count)
        }
        targetGroup.activePanelID = panelID
        targetGroup.isCollapsed = false
        document.groups[targetGroupID] = targetGroup

        return WorkspaceTransactionResult(didChange: true,
                                          changedRegions: changedRegions,
                                          focusPanelID: panelID,
                                          persistenceDirty: true)
    }

    private func reorderPanel(_ panelID: WorkspacePanelID,
                              in groupID: WorkspaceTabGroupID,
                              toIndex: Int) -> WorkspaceTransactionResult {
        guard var group = document.groups[groupID],
              let oldIndex = group.panels.firstIndex(of: panelID) else {
            return .unchanged
        }
        let pinnedBoundary = group.pinnedPanelIDs.count
        let isPinned = group.isPinned(panelID)
        let allowedRange = isPinned ? 0...pinnedBoundary : pinnedBoundary...group.panels.count
        let clamped = max(allowedRange.lowerBound, min(allowedRange.upperBound, toIndex))
        var next = group.panels
        next.remove(at: oldIndex)
        let adjusted = oldIndex < clamped ? clamped - 1 : clamped
        let insertIndex = max(0, min(next.count, adjusted))
        next.insert(panelID, at: insertIndex)
        guard next != group.panels else { return .unchanged }
        group.panels = next
        group.pinnedPanelIDs = group.pinnedPanelIDs.filter { group.panels.contains($0) }
        document.groups[groupID] = group
        return WorkspaceTransactionResult(didChange: true,
                                          changedRegions: [document.regionContaining(groupID: groupID)].compactSet(),
                                          focusPanelID: panelID,
                                          persistenceDirty: true)
    }

    private func closePanel(_ panelID: WorkspacePanelID) -> WorkspaceTransactionResult {
        guard document.panels[panelID]?.isClosable == true,
              let located = locate(panelID: panelID) else {
            return .unchanged
        }
        recordClosed(panelID: panelID,
                     groupID: located.group.id,
                     regionID: located.regionID,
                     floatingWindowID: located.floatingWindowID,
                     index: located.index)
        remove(panelID: panelID, from: located.group.id)
        return WorkspaceTransactionResult(didChange: true,
                                          changedRegions: [located.regionID].compactSet(),
                                          focusPanelID: document.groups[located.group.id]?.activePanelID,
                                          persistenceDirty: true)
    }

    private func closeOthers(groupID: WorkspaceTabGroupID,
                             keeping keepPanelID: WorkspacePanelID) -> WorkspaceTransactionResult {
        guard var group = document.groups[groupID],
              group.panels.contains(keepPanelID),
              let regionID = document.regionContaining(groupID: groupID) else {
            return .unchanged
        }
        let keepSet = Set(group.pinnedPanelIDs + [keepPanelID])
        let victims = group.panels.enumerated().filter { index, panelID in
            !keepSet.contains(panelID) && document.panels[panelID]?.isClosable == true
        }
        guard !victims.isEmpty else { return .unchanged }
        for (index, panelID) in victims {
            recordClosed(panelID: panelID,
                         groupID: groupID,
                         regionID: regionID,
                         floatingWindowID: nil,
                         index: index)
        }
        group.panels.removeAll { panelID in
            !keepSet.contains(panelID) && document.panels[panelID]?.isClosable == true
        }
        group.activePanelID = keepPanelID
        group.pinnedPanelIDs = group.pinnedPanelIDs.filter { group.panels.contains($0) }
        document.groups[groupID] = group
        return WorkspaceTransactionResult(didChange: true,
                                          changedRegions: [regionID],
                                          focusPanelID: keepPanelID,
                                          persistenceDirty: true)
    }

    private func closeToTheRight(groupID: WorkspaceTabGroupID,
                                 of pivotPanelID: WorkspacePanelID) -> WorkspaceTransactionResult {
        guard var group = document.groups[groupID],
              let pivot = group.panels.firstIndex(of: pivotPanelID),
              let regionID = document.regionContaining(groupID: groupID) else {
            return .unchanged
        }
        let victimPairs = group.panels.enumerated().filter { index, panelID in
            index > pivot && !group.isPinned(panelID) && document.panels[panelID]?.isClosable == true
        }
        guard !victimPairs.isEmpty else { return .unchanged }
        for (index, panelID) in victimPairs {
            recordClosed(panelID: panelID,
                         groupID: groupID,
                         regionID: regionID,
                         floatingWindowID: nil,
                         index: index)
        }
        let victims = Set(victimPairs.map(\.element))
        group.panels.removeAll { victims.contains($0) }
        if let active = group.activePanelID, victims.contains(active) {
            group.activePanelID = pivotPanelID
        }
        group.pinnedPanelIDs = group.pinnedPanelIDs.filter { group.panels.contains($0) }
        document.groups[groupID] = group
        return WorkspaceTransactionResult(didChange: true,
                                          changedRegions: [regionID],
                                          focusPanelID: group.activePanelID,
                                          persistenceDirty: true)
    }

    private func reopenLastClosed() -> WorkspaceTransactionResult {
        while let closed = document.closedHistory.popLast() {
            guard document.panels[closed.panelID] != nil,
                  locate(panelID: closed.panelID) == nil else {
                continue
            }
            let groupID: WorkspaceTabGroupID
            let restoreRegion = closed.regionID ?? .center
            if document.groups[closed.groupID] != nil {
                groupID = closed.groupID
                ensureGroup(groupID, in: restoreRegion)
            } else {
                groupID = closed.groupID
                document.groups[groupID] = WorkspaceTabGroup(id: groupID, panels: [])
                ensureGroup(groupID, in: restoreRegion)
            }
            var group = document.groups[groupID] ?? WorkspaceTabGroup(id: groupID, panels: [])
            insert(panelID: closed.panelID, into: &group, at: closed.index)
            group.activePanelID = closed.panelID
            group.isCollapsed = false
            document.groups[groupID] = group
            return WorkspaceTransactionResult(didChange: true,
                                              changedRegions: [restoreRegion],
                                              focusPanelID: closed.panelID,
                                              persistenceDirty: true)
        }
        return .unchanged
    }

    private func setPinned(panelID: WorkspacePanelID,
                           isPinned: Bool) -> WorkspaceTransactionResult {
        guard let located = locate(panelID: panelID) else { return .unchanged }
        var group = located.group
        let wasPinned = group.isPinned(panelID)
        guard wasPinned != isPinned else { return .unchanged }
        if isPinned {
            group.pinnedPanelIDs.append(panelID)
        } else {
            group.pinnedPanelIDs.removeAll { $0 == panelID }
        }
        group.panels.removeAll { $0 == panelID }
        let index = isPinned ? group.pinnedPanelIDs.count - 1 : group.pinnedPanelIDs.count
        group.panels.insert(panelID, at: max(0, min(group.panels.count, index)))
        document.groups[group.id] = group
        return WorkspaceTransactionResult(didChange: true,
                                          changedRegions: [located.regionID].compactSet(),
                                          focusPanelID: panelID,
                                          persistenceDirty: true)
    }

    private func floatGroup(_ groupID: WorkspaceTabGroupID,
                            windowID: WorkspaceFloatingWindowID,
                            frame: WorkspaceRect) -> WorkspaceTransactionResult {
        guard let group = document.groups[groupID],
              !group.panels.isEmpty,
              document.floatingWindowContaining(groupID: groupID) == nil,
              let regionID = document.regionContaining(groupID: groupID) else {
            return .unchanged
        }
        for index in document.regions.indices {
            document.regions[index].groupIDs.removeAll { $0 == groupID }
        }
        let zIndex = nextFloatingZIndex()
        let title = group.activePanelID.flatMap { document.panels[$0]?.title }
            ?? group.panels.first.flatMap { document.panels[$0]?.title }
            ?? groupID.rawValue
        document.floatingWindows.append(WorkspaceFloatingWindow(id: windowID,
                                                                groupID: groupID,
                                                                title: title,
                                                                frame: frame,
                                                                zIndex: zIndex))
        return WorkspaceTransactionResult(didChange: true,
                                          changedRegions: [regionID],
                                          focusPanelID: group.activePanelID,
                                          persistenceDirty: true)
    }

    private func redockFloatingWindow(_ windowID: WorkspaceFloatingWindowID,
                                      to target: WorkspaceTarget) -> WorkspaceTransactionResult {
        guard let windowIndex = document.floatingWindows.firstIndex(where: { $0.id == windowID }) else {
            return .unchanged
        }
        let window = document.floatingWindows.remove(at: windowIndex)
        guard document.groups[window.groupID] != nil else {
            return WorkspaceTransactionResult(didChange: true,
                                              changedRegions: [],
                                              focusPanelID: nil,
                                              persistenceDirty: true)
        }

        let destination = destination(for: target)
        insertExistingGroup(window.groupID, destination: destination)
        if var group = document.groups[window.groupID] {
            group.isCollapsed = false
            document.groups[window.groupID] = group
        }
        return WorkspaceTransactionResult(didChange: true,
                                          changedRegions: [destination.region],
                                          focusPanelID: document.groups[window.groupID]?.activePanelID,
                                          persistenceDirty: true)
    }

    private func moveFloatingWindow(_ windowID: WorkspaceFloatingWindowID,
                                    frame: WorkspaceRect) -> WorkspaceTransactionResult {
        guard let index = document.floatingWindows.firstIndex(where: { $0.id == windowID }),
              document.floatingWindows[index].frame != frame else {
            return .unchanged
        }
        document.floatingWindows[index].frame = frame
        return WorkspaceTransactionResult(didChange: true,
                                          changedRegions: [],
                                          focusPanelID: document.groups[document.floatingWindows[index].groupID]?.activePanelID,
                                          persistenceDirty: true)
    }

    private func focusFloatingWindow(_ windowID: WorkspaceFloatingWindowID) -> WorkspaceTransactionResult {
        guard let index = document.floatingWindows.firstIndex(where: { $0.id == windowID }) else {
            return .unchanged
        }
        let zIndex = nextFloatingZIndex()
        guard document.floatingWindows[index].zIndex != zIndex else { return .unchanged }
        document.floatingWindows[index].zIndex = zIndex
        let groupID = document.floatingWindows[index].groupID
        return WorkspaceTransactionResult(didChange: true,
                                          changedRegions: [],
                                          focusPanelID: document.groups[groupID]?.activePanelID,
                                          persistenceDirty: true)
    }

    private struct Destination {
        var region: WorkspaceRegionID
        var anchorGroupID: WorkspaceTabGroupID?
        var requiresAdjacentGroup: Bool
        var insertAfterAnchor: Bool
    }

    private func destination(for target: WorkspaceTarget) -> Destination {
        switch target.zone {
        case .tabGroup, .region:
            return Destination(region: target.region,
                               anchorGroupID: target.groupID,
                               requiresAdjacentGroup: false,
                               insertAfterAnchor: true)
        case .left:
            if target.region == .center {
                return Destination(region: .leading,
                                   anchorGroupID: nil,
                                   requiresAdjacentGroup: false,
                                   insertAfterAnchor: true)
            }
            return Destination(region: target.region,
                               anchorGroupID: target.groupID,
                               requiresAdjacentGroup: true,
                               insertAfterAnchor: false)
        case .right:
            if target.region == .center {
                return Destination(region: .trailing,
                                   anchorGroupID: nil,
                                   requiresAdjacentGroup: false,
                                   insertAfterAnchor: true)
            }
            return Destination(region: target.region,
                               anchorGroupID: target.groupID,
                               requiresAdjacentGroup: true,
                               insertAfterAnchor: true)
        case .top:
            return Destination(region: target.region,
                               anchorGroupID: target.groupID,
                               requiresAdjacentGroup: true,
                               insertAfterAnchor: false)
        case .bottom:
            if target.region == .center {
                return Destination(region: .bottom,
                                   anchorGroupID: nil,
                                   requiresAdjacentGroup: false,
                                   insertAfterAnchor: true)
            }
            return Destination(region: target.region,
                               anchorGroupID: target.groupID,
                               requiresAdjacentGroup: true,
                               insertAfterAnchor: true)
        }
    }

    private func remove(panelID: WorkspacePanelID,
                        from groupID: WorkspaceTabGroupID) {
        guard var group = document.groups[groupID] else { return }
        group.panels.removeAll { $0 == panelID }
        group.pinnedPanelIDs.removeAll { $0 == panelID }
        if group.panels.isEmpty {
            document.groups.removeValue(forKey: groupID)
            for index in document.regions.indices {
                document.regions[index].groupIDs.removeAll { $0 == groupID }
            }
            document.floatingWindows.removeAll { $0.groupID == groupID }
            return
        }
        if group.activePanelID == panelID {
            group.activePanelID = group.panels.first
        }
        document.groups[groupID] = group
    }

    private struct LocatedPanel {
        var regionID: WorkspaceRegionID?
        var floatingWindowID: WorkspaceFloatingWindowID?
        var group: WorkspaceTabGroup
        var index: Int
    }

    private func locate(panelID: WorkspacePanelID) -> LocatedPanel? {
        for region in document.regions {
            for groupID in region.groupIDs {
                guard let group = document.groups[groupID],
                      let index = group.panels.firstIndex(of: panelID) else {
                    continue
                }
                return LocatedPanel(regionID: region.id,
                                    floatingWindowID: nil,
                                    group: group,
                                    index: index)
            }
        }
        for window in document.floatingWindows {
            guard let group = document.groups[window.groupID],
                  let index = group.panels.firstIndex(of: panelID) else {
                continue
            }
            return LocatedPanel(regionID: nil,
                                floatingWindowID: window.id,
                                group: group,
                                index: index)
        }
        return nil
    }

    private func insert(panelID: WorkspacePanelID,
                        into group: inout WorkspaceTabGroup,
                        at requestedIndex: Int) {
        group.panels.removeAll { $0 == panelID }
        let pinnedBoundary = group.pinnedPanelIDs.count
        let insertIndex = max(pinnedBoundary, min(group.panels.count, requestedIndex))
        group.panels.insert(panelID, at: insertIndex)
    }

    private func recordClosed(panelID: WorkspacePanelID,
                              groupID: WorkspaceTabGroupID,
                              regionID: WorkspaceRegionID?,
                              floatingWindowID: WorkspaceFloatingWindowID?,
                              index: Int) {
        document.closedHistory.removeAll { $0.panelID == panelID }
        document.closedHistory.append(WorkspaceClosedPanel(panelID: panelID,
                                                           groupID: groupID,
                                                           regionID: regionID,
                                                           floatingWindowID: floatingWindowID,
                                                           index: index))
        if document.closedHistory.count > 64 {
            document.closedHistory.removeFirst(document.closedHistory.count - 64)
        }
    }

    private func firstGroupID(in regionID: WorkspaceRegionID) -> WorkspaceTabGroupID? {
        document.region(regionID).groupIDs.first
    }

    private func makeGroup(in regionID: WorkspaceRegionID,
                           adjacentTo anchorID: WorkspaceTabGroupID? = nil,
                           after: Bool = true) -> WorkspaceTabGroupID {
        let id = WorkspaceTabGroupID(rawValue: "\(regionID.rawValue)-\(UUID().uuidString)")
        document.groups[id] = WorkspaceTabGroup(id: id, panels: [])
        insertGroup(id, in: regionID, adjacentTo: anchorID, after: after)
        return id
    }

    private func makePrimaryGroup(in regionID: WorkspaceRegionID) -> WorkspaceTabGroupID {
        let id = WorkspaceTabGroupID(rawValue: regionID.rawValue)
        guard document.groups[id] == nil else {
            ensureGroup(id, in: regionID)
            return id
        }
        document.groups[id] = WorkspaceTabGroup(id: id, panels: [])
        ensureGroup(id, in: regionID)
        return id
    }

    private func ensureGroup(_ groupID: WorkspaceTabGroupID, in regionID: WorkspaceRegionID) {
        var region = document.region(regionID)
        guard !region.groupIDs.contains(groupID) else { return }
        region.groupIDs.append(groupID)
        document.setRegion(region)
    }

    private func insertGroup(_ groupID: WorkspaceTabGroupID,
                             in regionID: WorkspaceRegionID,
                             adjacentTo anchorID: WorkspaceTabGroupID?,
                             after: Bool) {
        var region = document.region(regionID)
        region.groupIDs.removeAll { $0 == groupID }
        if let anchorID,
           let anchorIndex = region.groupIDs.firstIndex(of: anchorID) {
            let insertionIndex = after ? region.groupIDs.index(after: anchorIndex) : anchorIndex
            region.groupIDs.insert(groupID, at: insertionIndex)
        } else {
            region.groupIDs.append(groupID)
        }
        document.setRegion(region)
    }

    private func insertExistingGroup(_ groupID: WorkspaceTabGroupID,
                                     destination: Destination) {
        for index in document.regions.indices {
            document.regions[index].groupIDs.removeAll { $0 == groupID }
        }
        if destination.requiresAdjacentGroup {
            insertGroup(groupID,
                        in: destination.region,
                        adjacentTo: destination.anchorGroupID,
                        after: destination.insertAfterAnchor)
        } else {
            insertGroup(groupID,
                        in: destination.region,
                        adjacentTo: destination.anchorGroupID,
                        after: true)
        }
    }

    private func nextFloatingZIndex() -> Int {
        (document.floatingWindows.map(\.zIndex).max() ?? 0) + 1
    }

    private func resizeSplit(_ splitID: WorkspaceSplitID,
                             fraction: Float) -> WorkspaceTransactionResult {
        let clamped = WorkspaceSplitFractions.clamp(fraction)
        let changed: Bool
        switch splitID.rawValue {
        case "leading":
            changed = document.splitFractions.leading != clamped
            document.splitFractions.leading = clamped
        case "centerTrailing":
            changed = document.splitFractions.centerTrailing != clamped
            document.splitFractions.centerTrailing = clamped
        case "topBottom":
            changed = document.splitFractions.topBottom != clamped
            document.splitFractions.topBottom = clamped
        default:
            return .unchanged
        }
        guard changed else { return .unchanged }
        return WorkspaceTransactionResult(didChange: true,
                                          changedRegions: Set(WorkspaceRegionID.allCases),
                                          focusPanelID: nil,
                                          persistenceDirty: true)
    }

    private func activeCenterPanel() -> WorkspacePanelID? {
        document.region(.center).groupIDs.lazy.compactMap { self.document.groups[$0]?.activePanelID }.first
    }

    private func notifyChange() {
        let callbacks = subscribers.values
        for callback in callbacks {
            callback(self)
        }
    }
}

private extension Array where Element == WorkspaceRegionID? {
    func compactSet() -> Set<WorkspaceRegionID> {
        Set(compactMap { $0 })
    }
}
