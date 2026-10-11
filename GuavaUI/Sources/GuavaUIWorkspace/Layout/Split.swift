import Foundation

/// A split is located by the groups on opposite sides of it. The common
/// ancestor remains stable when hidden branches are compacted for display.
public struct WorkspaceLayoutSplit: Sendable, Equatable {
    public let slot: WorkspaceSlotID
    public let firstGroup: WorkspaceTabGroupID
    public let secondGroup: WorkspaceTabGroupID

    public init(slot: WorkspaceSlotID, firstGroup: WorkspaceTabGroupID, secondGroup: WorkspaceTabGroupID) {
        self.slot = slot
        self.firstGroup = firstGroup
        self.secondGroup = secondGroup
    }
}

extension WorkspaceLayoutNode {
    func resizing(_ address: WorkspaceLayoutSplit, to fraction: Float) -> WorkspaceLayoutNode? {
        guard case let .split(axis, current, first, second) = self else { return nil }
        if first.contains(groupID: address.firstGroup), second.contains(groupID: address.secondGroup) {
            let next = WorkspaceSplitFractions.clamp(fraction)
            return next == current ? nil : .split(axis: axis, fraction: next, first: first, second: second)
        }
        if let next = first.resizing(address, to: fraction) {
            return .split(axis: axis, fraction: current, first: next, second: second)
        }
        if let next = second.resizing(address, to: fraction) {
            return .split(axis: axis, fraction: current, first: first, second: next)
        }
        return nil
    }
}
