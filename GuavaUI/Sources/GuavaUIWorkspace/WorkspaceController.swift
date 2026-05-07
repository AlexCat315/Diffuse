import Foundation

public enum WorkspacePlacementKind: String, Sendable, Codable, Equatable {
    case tabGroup
    case slot
    case split
}

public struct WorkspaceTarget: Sendable, Codable, Equatable {
    public var slot: WorkspaceSlotID
    public var groupID: WorkspaceTabGroupID?
    public var placement: WorkspacePlacementKind
    public var edge: WorkspaceEdge?
    public var tabIndex: Int?
    public var slotIndex: Int?
    public var fraction: Float

    public init(slot: WorkspaceSlotID,
                groupID: WorkspaceTabGroupID? = nil,
                placement: WorkspacePlacementKind = .tabGroup,
                edge: WorkspaceEdge? = nil,
                tabIndex: Int? = nil,
                slotIndex: Int? = nil,
                fraction: Float = 0.5) {
        self.slot = slot
        self.groupID = groupID
        self.placement = placement
        self.edge = edge
        self.tabIndex = tabIndex
        self.slotIndex = slotIndex
        self.fraction = WorkspaceSplitFractions.clamp(fraction)
    }

    public static func tabGroup(slot: WorkspaceSlotID,
                                groupID: WorkspaceTabGroupID,
                                tabIndex: Int? = nil) -> WorkspaceTarget {
        WorkspaceTarget(slot: slot,
                        groupID: groupID,
                        placement: .tabGroup,
                        tabIndex: tabIndex)
    }

    public static func slot(_ slot: WorkspaceSlotID,
                              index: Int? = nil) -> WorkspaceTarget {
        WorkspaceTarget(slot: slot,
                        placement: .slot,
                        slotIndex: index)
    }

    public static func split(slot: WorkspaceSlotID,
                             anchorGroupID: WorkspaceTabGroupID,
                             edge: WorkspaceEdge,
                             fraction: Float = 0.5) -> WorkspaceTarget {
        WorkspaceTarget(slot: slot,
                        groupID: anchorGroupID,
                        placement: .split,
                        edge: edge,
                        fraction: fraction)
    }
}

public struct WorkspaceHitTarget: Sendable, Equatable {
    public var slot: WorkspaceSlotID
    public var groupID: WorkspaceTabGroupID?
    public var panelID: WorkspacePanelID?
    public var target: WorkspaceTarget

    public init(slot: WorkspaceSlotID,
                groupID: WorkspaceTabGroupID? = nil,
                panelID: WorkspacePanelID? = nil,
                target: WorkspaceTarget) {
        self.slot = slot
        self.groupID = groupID
        self.panelID = panelID
        self.target = target
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
    public var changedSlots: Set<WorkspaceSlotID>
    public var focusPanelID: WorkspacePanelID?
    public var persistenceDirty: Bool

    public static let unchanged = WorkspaceTransactionResult(didChange: false,
                                                             changedSlots: [],
                                                             focusPanelID: nil,
                                                             persistenceDirty: false)

    public init(didChange: Bool,
                changedSlots: Set<WorkspaceSlotID>,
                focusPanelID: WorkspacePanelID?,
                persistenceDirty: Bool) {
        self.didChange = didChange
        self.changedSlots = changedSlots
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
                                              changedSlots: Set(document.slots.keys),
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
                                              changedSlots: [document.slotContaining(groupID: groupID)].compactSet(),
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
        guard let slotID = document.slotContaining(groupID: groupID),
              slotID != .center else {
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
        if collapsed {
            let edge = collapsedEdge(for: slotID)
            if !document.collapsed.contains(where: { $0.groupID == groupID }) {
                document.collapsed.append(WorkspaceCollapsedItem(groupID: groupID,
                                                                 slotID: slotID,
                                                                 edge: edge))
            }
        } else {
            document.collapsed.removeAll { $0.groupID == groupID }
        }
        return WorkspaceTransactionResult(didChange: true,
                                          changedSlots: [slotID],
                                          focusPanelID: collapsed ? nil : group.activePanelID,
                                          persistenceDirty: true)
    }

    private func movePanel(_ panelID: WorkspacePanelID,
                           to target: WorkspaceTarget) -> WorkspaceTransactionResult {
        guard document.panels[panelID] != nil else { return .unchanged }
        var changedSlots = Set<WorkspaceSlotID>()
        var sourceGroupID: WorkspaceTabGroupID?
        var sourceSlotID: WorkspaceSlotID?

        if let located = locate(panelID: panelID) {
            sourceGroupID = located.group.id
            sourceSlotID = located.slotID
        }

        if let sourceSlotID {
            changedSlots.insert(sourceSlotID)
        }

        let destination = destination(for: target)
        changedSlots.insert(destination.slot)

        if let sourceGroupID,
           sourceGroupID == target.groupID,
           destination.slot == sourceSlotID,
           destination.placement == .tabGroup {
            guard var group = document.groups[sourceGroupID] else { return .unchanged }
            let didChange = group.activePanelID != panelID || group.isCollapsed
            group.activePanelID = panelID
            group.isCollapsed = false
            document.groups[group.id] = group
            guard didChange else { return .unchanged }
            return WorkspaceTransactionResult(didChange: true,
                                              changedSlots: changedSlots,
                                              focusPanelID: panelID,
                                              persistenceDirty: true)
        }

        if let sourceGroupID {
            remove(panelID: panelID, from: sourceGroupID)
        }

        let targetGroupID: WorkspaceTabGroupID
        if destination.placement == .split,
           let edge = destination.splitEdge,
           let anchorID = destination.anchorGroupID {
            targetGroupID = makeGroup(in: destination.slot,
                                      splitFrom: anchorID,
                                      edge: edge,
                                      fraction: destination.fraction)
        } else if let groupID = destination.anchorGroupID,
                  document.groups[groupID] != nil {
            targetGroupID = groupID
            ensureGroup(groupID, in: destination.slot)
        } else {
            targetGroupID = firstGroupID(in: destination.slot) ?? makePrimaryGroup(in: destination.slot)
        }
        var targetGroup = document.groups[targetGroupID] ?? WorkspaceTabGroup(id: targetGroupID, panels: [])
        if !targetGroup.panels.contains(panelID) {
            insert(panelID: panelID, into: &targetGroup, at: targetGroup.panels.count)
        }
        targetGroup.activePanelID = panelID
        targetGroup.isCollapsed = false
        document.groups[targetGroupID] = targetGroup

        return WorkspaceTransactionResult(didChange: true,
                                          changedSlots: changedSlots,
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
                                          changedSlots: [document.slotContaining(groupID: groupID)].compactSet(),
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
                     slotID: located.slotID,
                     floatingWindowID: located.floatingWindowID,
                     index: located.index)
        remove(panelID: panelID, from: located.group.id)
        return WorkspaceTransactionResult(didChange: true,
                                          changedSlots: [located.slotID].compactSet(),
                                          focusPanelID: document.groups[located.group.id]?.activePanelID,
                                          persistenceDirty: true)
    }

    private func closeOthers(groupID: WorkspaceTabGroupID,
                             keeping keepPanelID: WorkspacePanelID) -> WorkspaceTransactionResult {
        guard var group = document.groups[groupID],
              group.panels.contains(keepPanelID),
              let slotID = document.slotContaining(groupID: groupID) else {
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
                         slotID: slotID,
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
                                          changedSlots: [slotID],
                                          focusPanelID: keepPanelID,
                                          persistenceDirty: true)
    }

    private func closeToTheRight(groupID: WorkspaceTabGroupID,
                                 of pivotPanelID: WorkspacePanelID) -> WorkspaceTransactionResult {
        guard var group = document.groups[groupID],
              let pivot = group.panels.firstIndex(of: pivotPanelID),
              let slotID = document.slotContaining(groupID: groupID) else {
            return .unchanged
        }
        let victimPairs = group.panels.enumerated().filter { index, panelID in
            index > pivot && !group.isPinned(panelID) && document.panels[panelID]?.isClosable == true
        }
        guard !victimPairs.isEmpty else { return .unchanged }
        for (index, panelID) in victimPairs {
            recordClosed(panelID: panelID,
                         groupID: groupID,
                         slotID: slotID,
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
                                          changedSlots: [slotID],
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
            let restoreSlot = closed.slotID ?? .center
            if document.groups[closed.groupID] != nil {
                groupID = closed.groupID
                ensureGroup(groupID, in: restoreSlot)
            } else {
                groupID = closed.groupID
                document.groups[groupID] = WorkspaceTabGroup(id: groupID, panels: [])
                ensureGroup(groupID, in: restoreSlot)
            }
            var group = document.groups[groupID] ?? WorkspaceTabGroup(id: groupID, panels: [])
            insert(panelID: closed.panelID, into: &group, at: closed.index)
            group.activePanelID = closed.panelID
            group.isCollapsed = false
            document.groups[groupID] = group
            return WorkspaceTransactionResult(didChange: true,
                                              changedSlots: [restoreSlot],
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
                                          changedSlots: [located.slotID].compactSet(),
                                          focusPanelID: panelID,
                                          persistenceDirty: true)
    }

    private func floatGroup(_ groupID: WorkspaceTabGroupID,
                            windowID: WorkspaceFloatingWindowID,
                            frame: WorkspaceRect) -> WorkspaceTransactionResult {
        guard let group = document.groups[groupID],
              !group.panels.isEmpty,
              document.floatingWindowContaining(groupID: groupID) == nil,
              let slotID = document.slotContaining(groupID: groupID) else {
            return .unchanged
        }
        removeGroupFromAllSlots(groupID)
        document.collapsed.removeAll { $0.groupID == groupID }
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
                                          changedSlots: [slotID],
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
                                              changedSlots: [],
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
                                          changedSlots: [destination.slot],
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
                                          changedSlots: [],
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
                                          changedSlots: [],
                                          focusPanelID: document.groups[groupID]?.activePanelID,
                                          persistenceDirty: true)
    }

    private struct Destination {
        var slot: WorkspaceSlotID
        var anchorGroupID: WorkspaceTabGroupID?
        var placement: WorkspacePlacementKind
        var splitEdge: WorkspaceEdge?
        var insertionIndex: Int?
        var fraction: Float
    }

    private func destination(for target: WorkspaceTarget) -> Destination {
        Destination(slot: target.slot,
                    anchorGroupID: target.groupID,
                    placement: target.placement,
                    splitEdge: target.edge,
                    insertionIndex: target.slotIndex,
                    fraction: target.fraction)
    }

    private func remove(panelID: WorkspacePanelID,
                        from groupID: WorkspaceTabGroupID) {
        guard var group = document.groups[groupID] else { return }
        group.panels.removeAll { $0 == panelID }
        group.pinnedPanelIDs.removeAll { $0 == panelID }
        if group.panels.isEmpty {
            document.groups.removeValue(forKey: groupID)
            removeGroupFromAllSlots(groupID)
            document.collapsed.removeAll { $0.groupID == groupID }
            document.floatingWindows.removeAll { $0.groupID == groupID }
            return
        }
        if group.activePanelID == panelID {
            group.activePanelID = group.panels.first
        }
        document.groups[groupID] = group
    }

    private struct LocatedPanel {
        var slotID: WorkspaceSlotID?
        var floatingWindowID: WorkspaceFloatingWindowID?
        var group: WorkspaceTabGroup
        var index: Int
    }

    private func locate(panelID: WorkspacePanelID) -> LocatedPanel? {
        for slot in document.slots.values {
            for groupID in slot.layout?.leafGroupIDs ?? [] {
                guard let group = document.groups[groupID],
                      let index = group.panels.firstIndex(of: panelID) else {
                    continue
                }
                return LocatedPanel(slotID: slot.id,
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
            return LocatedPanel(slotID: nil,
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
                              slotID: WorkspaceSlotID?,
                              floatingWindowID: WorkspaceFloatingWindowID?,
                              index: Int) {
        document.closedHistory.removeAll { $0.panelID == panelID }
        document.closedHistory.append(WorkspaceClosedPanel(panelID: panelID,
                                                           groupID: groupID,
                                                           slotID: slotID,
                                                           floatingWindowID: floatingWindowID,
                                                           index: index))
        if document.closedHistory.count > 64 {
            document.closedHistory.removeFirst(document.closedHistory.count - 64)
        }
    }

    private func firstGroupID(in slotID: WorkspaceSlotID) -> WorkspaceTabGroupID? {
        document.slot(slotID).layout?.leafGroupIDs.first
    }

    private func makeGroup(in slotID: WorkspaceSlotID,
                           splitFrom anchorID: WorkspaceTabGroupID? = nil,
                           edge: WorkspaceEdge? = nil,
                           fraction: Float = 0.5) -> WorkspaceTabGroupID {
        let id = WorkspaceTabGroupID(rawValue: "\(slotID.rawValue)-\(UUID().uuidString)")
        document.groups[id] = WorkspaceTabGroup(id: id, panels: [])
        insertGroup(id, in: slotID, splitFrom: anchorID, edge: edge, fraction: fraction)
        return id
    }

    private func makePrimaryGroup(in slotID: WorkspaceSlotID) -> WorkspaceTabGroupID {
        let id = WorkspaceTabGroupID(rawValue: slotID.rawValue)
        guard document.groups[id] == nil else {
            ensureGroup(id, in: slotID)
            return id
        }
        document.groups[id] = WorkspaceTabGroup(id: id, panels: [])
        ensureGroup(id, in: slotID)
        return id
    }

    private func ensureGroup(_ groupID: WorkspaceTabGroupID, in slotID: WorkspaceSlotID) {
        var slot = document.slot(slotID)
        guard !slot.containsGroup(groupID) else { return }
        slot.layout = append(groupID: groupID, to: slot.layout)
        document.setSlot(slot)
    }

    private func insertGroup(_ groupID: WorkspaceTabGroupID,
                             in slotID: WorkspaceSlotID,
                             splitFrom anchorID: WorkspaceTabGroupID?,
                             edge: WorkspaceEdge?,
                             fraction: Float) {
        var slot = document.slot(slotID)
        slot.layout = remove(groupID: groupID, from: slot.layout)
        if let anchorID,
           let edge,
           contains(groupID: anchorID, in: slot.layout) {
            slot.layout = split(anchorGroupID: anchorID,
                                  insertedGroupID: groupID,
                                  edge: edge,
                                  fraction: fraction,
                                  in: slot.layout)
        } else {
            slot.layout = append(groupID: groupID, to: slot.layout)
        }
        document.setSlot(slot)
    }

    private func insertExistingGroup(_ groupID: WorkspaceTabGroupID,
                                     destination: Destination) {
        removeGroupFromAllSlots(groupID)
        document.collapsed.removeAll { $0.groupID == groupID }
        if destination.placement == .split,
           let edge = destination.splitEdge {
            insertGroup(groupID,
                        in: destination.slot,
                        splitFrom: destination.anchorGroupID,
                        edge: edge,
                        fraction: destination.fraction)
        } else {
            insertGroup(groupID,
                        in: destination.slot,
                        splitFrom: nil,
                        edge: nil,
                        fraction: destination.fraction)
        }
    }

    private func nextFloatingZIndex() -> Int {
        (document.floatingWindows.map(\.zIndex).max() ?? 0) + 1
    }

    private func removeGroupFromAllSlots(_ groupID: WorkspaceTabGroupID) {
        for slotID in Array(document.slots.keys) {
            let layout = document.slots[slotID]?.layout
            document.slots[slotID]?.layout = remove(groupID: groupID, from: layout)
        }
    }

    private func contains(groupID: WorkspaceTabGroupID,
                          in node: WorkspaceLayoutNode?) -> Bool {
        node?.contains(groupID: groupID) == true
    }

    private func append(groupID: WorkspaceTabGroupID,
                        to node: WorkspaceLayoutNode?) -> WorkspaceLayoutNode {
        guard let node else {
            return .group(groupID)
        }
        return .split(axis: .vertical,
                      fraction: 0.5,
                      first: node,
                      second: .group(groupID))
    }

    private func remove(groupID: WorkspaceTabGroupID,
                        from node: WorkspaceLayoutNode?) -> WorkspaceLayoutNode? {
        guard let node else { return nil }
        switch node {
        case .group(let current):
            return current == groupID ? nil : node
        case .split(let axis, let fraction, let first, let second):
            let nextFirst = remove(groupID: groupID, from: first)
            let nextSecond = remove(groupID: groupID, from: second)
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

    private func split(anchorGroupID: WorkspaceTabGroupID,
                       insertedGroupID: WorkspaceTabGroupID,
                       edge: WorkspaceEdge,
                       fraction: Float,
                       in node: WorkspaceLayoutNode?) -> WorkspaceLayoutNode {
        guard let node else {
            return .group(insertedGroupID)
        }
        switch node {
        case .group(let current) where current == anchorGroupID:
            let inserted = WorkspaceLayoutNode.group(insertedGroupID)
            let anchor = WorkspaceLayoutNode.group(anchorGroupID)
            if edge.insertsBeforeAnchor {
                return .split(axis: edge.splitAxis,
                              fraction: fraction,
                              first: inserted,
                              second: anchor)
            }
            return .split(axis: edge.splitAxis,
                          fraction: 1 - fraction,
                          first: anchor,
                          second: inserted)
        case .group:
            return node
        case .split(let axis, let currentFraction, let first, let second):
            return .split(axis: axis,
                          fraction: currentFraction,
                          first: split(anchorGroupID: anchorGroupID,
                                       insertedGroupID: insertedGroupID,
                                       edge: edge,
                                       fraction: fraction,
                                       in: first),
                          second: split(anchorGroupID: anchorGroupID,
                                        insertedGroupID: insertedGroupID,
                                        edge: edge,
                                        fraction: fraction,
                                        in: second))
        }
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
                                          changedSlots: Set(document.slots.keys),
                                          focusPanelID: nil,
                                          persistenceDirty: true)
    }

    private func activeCenterPanel() -> WorkspacePanelID? {
        (document.slot(.center).layout?.leafGroupIDs ?? []).lazy.compactMap { self.document.groups[$0]?.activePanelID }.first
    }

    private func collapsedEdge(for slotID: WorkspaceSlotID) -> WorkspaceEdge {
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

    private func notifyChange() {
        let callbacks = subscribers.values
        for callback in callbacks {
            callback(self)
        }
    }
}

private extension Array where Element == WorkspaceSlotID? {
    func compactSet() -> Set<WorkspaceSlotID> {
        Set(compactMap { $0 })
    }
}
