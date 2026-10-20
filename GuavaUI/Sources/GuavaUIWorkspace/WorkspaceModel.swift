import Foundation
import GuavaUICompose

public struct WorkspacePanelID: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

public struct WorkspaceTabGroupID: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

public struct WorkspaceSplitID: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

public struct WorkspaceFloatingWindowID: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

public struct WorkspaceSlotID: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    public static let content = WorkspaceSlotID(rawValue: "content")
    public static let leading = WorkspaceSlotID(rawValue: "leading")
    public static let center = WorkspaceSlotID(rawValue: "center")
    public static let trailing = WorkspaceSlotID(rawValue: "trailing")
    public static let top = WorkspaceSlotID(rawValue: "top")
    public static let bottom = WorkspaceSlotID(rawValue: "bottom")
    public static let overlay = WorkspaceSlotID(rawValue: "overlay")
    public static let floating = WorkspaceSlotID(rawValue: "floating")

    public static let standardEditorSlots: [WorkspaceSlotID] = [.leading, .center, .trailing, .bottom]
}

public enum WorkspaceSplitAxis: String, Sendable, Codable, Equatable {
    case horizontal
    case vertical
}

public enum WorkspaceEdge: String, Sendable, Codable, Equatable {
    case leading
    case trailing
    case top
    case bottom

    public var splitAxis: WorkspaceSplitAxis {
        switch self {
        case .leading, .trailing:
            return .horizontal
        case .top, .bottom:
            return .vertical
        }
    }

    public var insertsBeforeAnchor: Bool {
        switch self {
        case .leading, .top:
            return true
        case .trailing, .bottom:
            return false
        }
    }
}

public extension WorkspaceSlotID {
    static let chromeLeadingRail = WorkspaceSlotID(rawValue: "chrome.leading.rail")
    static let chromeTrailingRail = WorkspaceSlotID(rawValue: "chrome.trailing.rail")
    static let chromeTopRail = WorkspaceSlotID(rawValue: "chrome.top.rail")
    static let chromeBottomRail = WorkspaceSlotID(rawValue: "chrome.bottom.rail")

    static func chromeRail(for edge: WorkspaceEdge) -> WorkspaceSlotID {
        switch edge {
        case .leading:
            return .chromeLeadingRail
        case .trailing:
            return .chromeTrailingRail
        case .top:
            return .chromeTopRail
        case .bottom:
            return .chromeBottomRail
        }
    }
}

public indirect enum WorkspaceLayoutNode: Sendable, Codable, Equatable {
    case group(WorkspaceTabGroupID)
    case split(axis: WorkspaceSplitAxis,
               fraction: Float,
               first: WorkspaceLayoutNode,
               second: WorkspaceLayoutNode)

    public var leafGroupIDs: [WorkspaceTabGroupID] {
        switch self {
        case .group(let groupID):
            return [groupID]
        case .split(_, _, let first, let second):
            return first.leafGroupIDs + second.leafGroupIDs
        }
    }

    public func contains(groupID: WorkspaceTabGroupID) -> Bool {
        leafGroupIDs.contains(groupID)
    }

    public static func stacked(_ leafGroupIDs: [WorkspaceTabGroupID],
                               axis: WorkspaceSplitAxis = .vertical,
                               fraction: Float = 0.5) -> WorkspaceLayoutNode? {
        var iterator = leafGroupIDs.makeIterator()
        guard var root = iterator.next().map(WorkspaceLayoutNode.group) else {
            return nil
        }
        while let next = iterator.next() {
            root = .split(axis: axis,
                          fraction: fraction,
                          first: root,
                          second: .group(next))
        }
        return root
    }

    public func appending(groupID: WorkspaceTabGroupID,
                          axis: WorkspaceSplitAxis = .vertical,
                          fraction: Float = 0.5) -> WorkspaceLayoutNode {
        .split(axis: axis,
               fraction: fraction,
               first: self,
               second: .group(groupID))
    }

    public func removing(groupID: WorkspaceTabGroupID) -> WorkspaceLayoutNode? {
        switch self {
        case .group(let current):
            return current == groupID ? nil : self
        case .split(let axis, let fraction, let first, let second):
            let nextFirst = first.removing(groupID: groupID)
            let nextSecond = second.removing(groupID: groupID)
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
}

public struct WorkspaceRect: Sendable, Codable, Equatable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float = 120,
                y: Float = 80,
                width: Float = 520,
                height: Float = 420) {
        self.x = x
        self.y = y
        self.width = max(160, width)
        self.height = max(120, height)
    }
}

public struct WorkspacePanel: Sendable, Codable, Equatable {
    public var id: WorkspacePanelID
    public var title: String
    public var isClosable: Bool
    public var isDraggable: Bool
    public var isCollapsible: Bool
    public var iconAssetKey: String?
    /// A panel that draws its own tabs, such as a code editor with file tabs,
    /// hides the group tab bar while it is the only panel in its group.
    public var hidesTabBarWhenAlone = false
    public var sizing = WorkspacePanelSizing()

    public init(id: WorkspacePanelID,
                title: String,
                isClosable: Bool = true,
                isDraggable: Bool = true,
                isCollapsible: Bool = true,
                iconAssetKey: String? = nil,
                sizing: WorkspacePanelSizing = .init()) {
        self.id = id
        self.title = title
        self.isClosable = isClosable
        self.isDraggable = isDraggable
        self.isCollapsible = isCollapsible
        self.iconAssetKey = iconAssetKey
        self.sizing = sizing
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, isClosable, isDraggable, isCollapsible, iconAssetKey, hidesTabBarWhenAlone, sizing
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(WorkspacePanelID.self, forKey: .id),
                  title: try values.decode(String.self, forKey: .title),
                  isClosable: try values.decodeIfPresent(Bool.self, forKey: .isClosable) ?? true,
                  isDraggable: try values.decodeIfPresent(Bool.self, forKey: .isDraggable) ?? true,
                  isCollapsible: try values.decodeIfPresent(Bool.self, forKey: .isCollapsible) ?? true,
                  iconAssetKey: try values.decodeIfPresent(String.self, forKey: .iconAssetKey),
                  sizing: try values.decodeIfPresent(WorkspacePanelSizing.self, forKey: .sizing) ?? .init())
        hidesTabBarWhenAlone = try values.decodeIfPresent(Bool.self, forKey: .hidesTabBarWhenAlone) ?? false
    }
}

public struct WorkspaceTabGroup: Sendable, Codable, Equatable {
    public var id: WorkspaceTabGroupID
    public var panels: [WorkspacePanelID]
    public var activePanelID: WorkspacePanelID?
    public var isCollapsed: Bool
    public var pinnedPanelIDs: [WorkspacePanelID]

    public init(id: WorkspaceTabGroupID,
                panels: [WorkspacePanelID],
                activePanelID: WorkspacePanelID? = nil,
                isCollapsed: Bool = false,
                pinnedPanelIDs: [WorkspacePanelID] = []) {
        self.id = id
        self.panels = panels
        self.activePanelID = activePanelID ?? panels.first
        self.isCollapsed = isCollapsed
        self.pinnedPanelIDs = pinnedPanelIDs.filter { panels.contains($0) }
    }

    public func isPinned(_ panelID: WorkspacePanelID) -> Bool {
        pinnedPanelIDs.contains(panelID)
    }
}

public enum WorkspaceSlotSize: Sendable, Codable, Equatable {
    case fixed(Float)
    case fraction(Float)

    public var fixedValue: Float? {
        if case .fixed(let value) = self { return value }
        return nil
    }
}

public enum WorkspaceSlotKind: Sendable, Codable, Equatable {
    case content
    case chrome(edge: WorkspaceEdge, size: WorkspaceSlotSize)
    case overlay
    case floating
}

public struct WorkspaceSlot: Sendable, Codable, Equatable {
    public var id: WorkspaceSlotID
    public var kind: WorkspaceSlotKind
    public var layout: WorkspaceLayoutNode?

    public init(id: WorkspaceSlotID,
                kind: WorkspaceSlotKind = .content,
                layout: WorkspaceLayoutNode? = nil) {
        self.id = id
        self.kind = kind
        self.layout = layout
    }

    public func containsGroup(_ groupID: WorkspaceTabGroupID) -> Bool {
        layout?.contains(groupID: groupID) == true
    }

    public mutating func appendGroup(_ groupID: WorkspaceTabGroupID) {
        guard !containsGroup(groupID) else { return }
        layout = layout?.appending(groupID: groupID) ?? .group(groupID)
    }

    public mutating func removeGroup(_ groupID: WorkspaceTabGroupID) {
        layout = layout?.removing(groupID: groupID)
    }

    public static func standardEditorSlots(leading: WorkspaceLayoutNode? = nil,
                                           center: WorkspaceLayoutNode? = nil,
                                           trailing: WorkspaceLayoutNode? = nil,
                                           bottom: WorkspaceLayoutNode? = nil) -> [WorkspaceSlotID: WorkspaceSlot] {
        var slots: [WorkspaceSlotID: WorkspaceSlot] = [
            .leading: WorkspaceSlot(id: .leading,
                                    kind: .content,
                                    layout: leading),
            .center: WorkspaceSlot(id: .center,
                                   kind: .content,
                                   layout: center),
            .trailing: WorkspaceSlot(id: .trailing,
                                     kind: .content,
                                     layout: trailing),
            .bottom: WorkspaceSlot(id: .bottom,
                                   kind: .content,
                                   layout: bottom),
            .overlay: WorkspaceSlot(id: .overlay, kind: .overlay),
            .floating: WorkspaceSlot(id: .floating, kind: .floating),
        ]
        for (slotID, slot) in standardEditorChromeRailSlots() {
            slots[slotID] = slot
        }
        return slots
    }

    public static func standardEditorChromeRailSlots() -> [WorkspaceSlotID: WorkspaceSlot] {
        [
            .chromeLeadingRail: WorkspaceSlot(id: .chromeLeadingRail,
                                             kind: .chrome(edge: .leading, size: .fixed(40))),
            .chromeTrailingRail: WorkspaceSlot(id: .chromeTrailingRail,
                                              kind: .chrome(edge: .trailing, size: .fixed(40))),
            .chromeBottomRail: WorkspaceSlot(id: .chromeBottomRail,
                                            kind: .chrome(edge: .bottom, size: .fixed(40))),
        ]
    }
}

/// Nil preserves the panels' preferred initial size. A user resize writes an
/// explicit fraction, which survives window changes and document round trips.
public struct WorkspaceSplitFractions: Sendable, Codable, Equatable {
    public var leading: Float?
    public var centerTrailing: Float?
    public var topBottom: Float?
    public var top: Float?

    public init(leading: Float? = nil, centerTrailing: Float? = nil,
                topBottom: Float? = nil, top: Float? = nil) {
        self.leading = leading.map(Self.clamp)
        self.centerTrailing = centerTrailing.map(Self.clamp)
        self.topBottom = topBottom.map(Self.clamp)
        self.top = top.map(Self.clamp)
    }

    public static func clamp(_ value: Float) -> Float {
        value.isFinite ? max(0, min(1, value)) : 0.5
    }
}

public struct WorkspaceFloatingWindow: Sendable, Codable, Equatable {
    public var id: WorkspaceFloatingWindowID
    public var groupID: WorkspaceTabGroupID
    public var title: String
    public var frame: WorkspaceRect
    public var zIndex: Int

    public init(id: WorkspaceFloatingWindowID = WorkspaceFloatingWindowID(rawValue: UUID().uuidString),
                groupID: WorkspaceTabGroupID,
                title: String,
                frame: WorkspaceRect = WorkspaceRect(),
                zIndex: Int = 0) {
        self.id = id
        self.groupID = groupID
        self.title = title
        self.frame = frame
        self.zIndex = zIndex
    }
}

public struct WorkspaceClosedPanel: Sendable, Codable, Equatable {
    public var panelID: WorkspacePanelID
    public var groupID: WorkspaceTabGroupID
    public var slotID: WorkspaceSlotID?
    public var floatingWindowID: WorkspaceFloatingWindowID?
    public var index: Int

    public init(panelID: WorkspacePanelID,
                groupID: WorkspaceTabGroupID,
                slotID: WorkspaceSlotID?,
                floatingWindowID: WorkspaceFloatingWindowID? = nil,
                index: Int) {
        self.panelID = panelID
        self.groupID = groupID
        self.slotID = slotID
        self.floatingWindowID = floatingWindowID
        self.index = index
    }
}

public struct WorkspaceCollapsedItem: Sendable, Codable, Equatable {
    public var groupID: WorkspaceTabGroupID
    public var slotID: WorkspaceSlotID
    public var edge: WorkspaceEdge

    public init(groupID: WorkspaceTabGroupID,
                slotID: WorkspaceSlotID,
                edge: WorkspaceEdge) {
        self.groupID = groupID
        self.slotID = slotID
        self.edge = edge
    }
}

public struct WorkspaceDocument: Sendable, Codable, Equatable {
    public var panels: [WorkspacePanelID: WorkspacePanel]
    public var groups: [WorkspaceTabGroupID: WorkspaceTabGroup]
    public var slots: [WorkspaceSlotID: WorkspaceSlot]
    public var collapsed: [WorkspaceCollapsedItem]
    public var floatingWindows: [WorkspaceFloatingWindow]
    public var splitFractions: WorkspaceSplitFractions
    public var closedHistory: [WorkspaceClosedPanel]

    public init(panels: [WorkspacePanelID: WorkspacePanel],
                groups: [WorkspaceTabGroupID: WorkspaceTabGroup],
                slots: [WorkspaceSlotID: WorkspaceSlot],
                collapsed: [WorkspaceCollapsedItem] = [],
                floatingWindows: [WorkspaceFloatingWindow] = [],
                splitFractions: WorkspaceSplitFractions = WorkspaceSplitFractions(),
                closedHistory: [WorkspaceClosedPanel] = []) {
        self.panels = panels
        self.groups = groups
        self.slots = slots
        self.collapsed = collapsed
        self.floatingWindows = floatingWindows
        self.splitFractions = splitFractions
        self.closedHistory = closedHistory
    }

    public func slot(_ id: WorkspaceSlotID) -> WorkspaceSlot {
        slots[id] ?? WorkspaceSlot(id: id)
    }

    public mutating func setSlot(_ slot: WorkspaceSlot) {
        slots[slot.id] = slot
    }

    public mutating func ensureStandardEditorSlotSchema() {
        for (slotID, slot) in WorkspaceSlot.standardEditorSlots() where slots[slotID] == nil {
            slots[slotID] = slot
        }
    }

    public func group(_ id: WorkspaceTabGroupID) -> WorkspaceTabGroup? {
        groups[id]
    }

    public func panel(_ id: WorkspacePanelID) -> WorkspacePanel? {
        panels[id]
    }

    public func groupContaining(panelID: WorkspacePanelID) -> WorkspaceTabGroup? {
        groups.values.first { $0.panels.contains(panelID) }
    }

    public func slotContaining(groupID: WorkspaceTabGroupID) -> WorkspaceSlotID? {
        slots.values.first { $0.containsGroup(groupID) }?.id
    }

    public func floatingWindowContaining(groupID: WorkspaceTabGroupID) -> WorkspaceFloatingWindow? {
        floatingWindows.first { $0.groupID == groupID }
    }

    public var referencedLayoutGroupIDs: Set<WorkspaceTabGroupID> {
        Set(slots.values.flatMap { $0.layout?.leafGroupIDs ?? [] })
    }

    public var referencedFloatingGroupIDs: Set<WorkspaceTabGroupID> {
        Set(floatingWindows.map(\.groupID))
    }

    public var hasValidLayoutReferences: Bool {
        let layoutGroupIDs = referencedLayoutGroupIDs
        let floatingGroupIDs = referencedFloatingGroupIDs
        let attachedGroupIDs = layoutGroupIDs.union(floatingGroupIDs)

        guard layoutGroupIDs.allSatisfy({ groups[$0] != nil }),
              floatingGroupIDs.allSatisfy({ groups[$0] != nil }) else {
            return false
        }

        for (groupID, group) in groups where !group.panels.isEmpty {
            guard attachedGroupIDs.contains(groupID) else {
                return false
            }
        }
        return true
    }
}

/// Authored panel metadata has one representation; the factory is transient.
public struct WorkspacePanelDescriptor {
    public var panel: WorkspacePanel
    public var defaultSlot: WorkspaceSlotID
    public let factory: () -> AnyView

    public init<Content: View>(id: WorkspacePanelID, title: String,
                               defaultSlot: WorkspaceSlotID = .center,
                               configure: (inout WorkspacePanel) -> Void = { _ in },
                               @ViewBuilder content: @escaping () -> Content) {
        panel = WorkspacePanel(id: id, title: title)
        configure(&panel)
        self.defaultSlot = defaultSlot
        factory = { AnyView(content()) }
    }
}

public final class WorkspacePanelRegistry {
    private var byID: [WorkspacePanelID: WorkspacePanelDescriptor] = [:]
    private var order: [WorkspacePanelID] = []

    public init() {}

    public init(_ descriptors: [WorkspacePanelDescriptor]) {
        for descriptor in descriptors {
            register(descriptor)
        }
    }

    public func register(_ descriptor: WorkspacePanelDescriptor) {
        if byID[descriptor.panel.id] == nil {
            order.append(descriptor.panel.id)
        }
        byID[descriptor.panel.id] = descriptor
    }

    public func updateDescriptor(id: WorkspacePanelID,
                                 _ update: (inout WorkspacePanelDescriptor) -> Void) {
        guard var descriptor = byID[id] else { return }
        update(&descriptor)
        precondition(descriptor.panel.id == id, "Updating a descriptor cannot change its panel identity")
        byID[id] = descriptor
    }

    public func descriptor(for id: WorkspacePanelID) -> WorkspacePanelDescriptor? {
        byID[id]
    }

    public func make(_ id: WorkspacePanelID) -> AnyView {
        byID[id]?.factory() ?? AnyView(EmptyView())
    }

    public func unregister(id: WorkspacePanelID) {
        byID.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    public var count: Int { byID.count }
    public var isEmpty: Bool { byID.isEmpty }
    public var ids: [WorkspacePanelID] { order }
    public var descriptors: [WorkspacePanelDescriptor] { order.compactMap { byID[$0] } }
}
