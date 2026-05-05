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
    case movePanel(WorkspacePanelID, to: WorkspaceTarget)
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
        case .movePanel(let panelID, let target):
            return movePanel(panelID, to: target)
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
        guard document.regionContaining(groupID: groupID) != .center else {
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
        let region = document.regionContaining(groupID: groupID)
        return WorkspaceTransactionResult(didChange: true,
                                          changedRegions: [region].compactSet(),
                                          focusPanelID: collapsed ? nil : group.activePanelID,
                                          persistenceDirty: true)
    }

    private func movePanel(_ panelID: WorkspacePanelID,
                           to target: WorkspaceTarget) -> WorkspaceTransactionResult {
        guard document.panels[panelID] != nil else { return .unchanged }
        var changedRegions = Set<WorkspaceRegionID>()
        var sourceGroupID: WorkspaceTabGroupID?
        var sourceRegionID: WorkspaceRegionID?

        for region in document.regions {
            for groupID in region.groupIDs {
                guard let group = document.groups[groupID],
                      group.panels.contains(panelID) else {
                    continue
                }
                sourceGroupID = groupID
                sourceRegionID = region.id
                break
            }
        }

        if let sourceRegionID {
            changedRegions.insert(sourceRegionID)
        }
        changedRegions.insert(target.region)

        if let sourceGroupID {
            remove(panelID: panelID, from: sourceGroupID)
        }

        let targetGroupID = target.groupID ?? firstGroupID(in: target.region) ?? makeGroup(in: target.region)
        ensureGroup(targetGroupID, in: target.region)
        var targetGroup = document.groups[targetGroupID] ?? WorkspaceTabGroup(id: targetGroupID, panels: [])
        if !targetGroup.panels.contains(panelID) {
            targetGroup.panels.append(panelID)
        }
        targetGroup.activePanelID = panelID
        targetGroup.isCollapsed = false
        document.groups[targetGroupID] = targetGroup

        return WorkspaceTransactionResult(didChange: true,
                                          changedRegions: changedRegions,
                                          focusPanelID: panelID,
                                          persistenceDirty: true)
    }

    private func remove(panelID: WorkspacePanelID,
                        from groupID: WorkspaceTabGroupID) {
        guard var group = document.groups[groupID] else { return }
        group.panels.removeAll { $0 == panelID }
        if group.panels.isEmpty {
            document.groups.removeValue(forKey: groupID)
            for index in document.regions.indices {
                document.regions[index].groupIDs.removeAll { $0 == groupID }
            }
            return
        }
        if group.activePanelID == panelID {
            group.activePanelID = group.panels.first
        }
        document.groups[groupID] = group
    }

    private func firstGroupID(in regionID: WorkspaceRegionID) -> WorkspaceTabGroupID? {
        document.region(regionID).groupIDs.first
    }

    private func makeGroup(in regionID: WorkspaceRegionID) -> WorkspaceTabGroupID {
        let id = WorkspaceTabGroupID(rawValue: "\(regionID.rawValue)-\(UUID().uuidString)")
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
