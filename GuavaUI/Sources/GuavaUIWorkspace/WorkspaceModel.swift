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

public enum WorkspaceRegionID: String, Sendable, Codable, CaseIterable {
    case leading
    case center
    case trailing
    case bottom
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

    public init(id: WorkspacePanelID,
                title: String,
                isClosable: Bool = true,
                isDraggable: Bool = true,
                isCollapsible: Bool = true,
                iconAssetKey: String? = nil) {
        self.id = id
        self.title = title
        self.isClosable = isClosable
        self.isDraggable = isDraggable
        self.isCollapsible = isCollapsible
        self.iconAssetKey = iconAssetKey
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

public struct WorkspaceRegion: Sendable, Codable, Equatable {
    public var id: WorkspaceRegionID
    public var groupIDs: [WorkspaceTabGroupID]

    public init(id: WorkspaceRegionID,
                groupIDs: [WorkspaceTabGroupID] = []) {
        self.id = id
        self.groupIDs = groupIDs
    }
}

public struct WorkspaceSplitFractions: Sendable, Codable, Equatable {
    public var leading: Float
    public var centerTrailing: Float
    public var topBottom: Float

    public init(leading: Float = 0.22,
                centerTrailing: Float = 0.78,
                topBottom: Float = 0.74) {
        self.leading = WorkspaceSplitFractions.clamp(leading)
        self.centerTrailing = WorkspaceSplitFractions.clamp(centerTrailing)
        self.topBottom = WorkspaceSplitFractions.clamp(topBottom)
    }

    public static func clamp(_ value: Float) -> Float {
        max(0.05, min(0.95, value))
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
    public var regionID: WorkspaceRegionID?
    public var floatingWindowID: WorkspaceFloatingWindowID?
    public var index: Int

    public init(panelID: WorkspacePanelID,
                groupID: WorkspaceTabGroupID,
                regionID: WorkspaceRegionID?,
                floatingWindowID: WorkspaceFloatingWindowID? = nil,
                index: Int) {
        self.panelID = panelID
        self.groupID = groupID
        self.regionID = regionID
        self.floatingWindowID = floatingWindowID
        self.index = index
    }
}

public struct WorkspaceDocument: Sendable, Codable, Equatable {
    public var panels: [WorkspacePanelID: WorkspacePanel]
    public var groups: [WorkspaceTabGroupID: WorkspaceTabGroup]
    public var regions: [WorkspaceRegion]
    public var floatingWindows: [WorkspaceFloatingWindow]
    public var splitFractions: WorkspaceSplitFractions
    public var closedHistory: [WorkspaceClosedPanel]

    public init(panels: [WorkspacePanelID: WorkspacePanel],
                groups: [WorkspaceTabGroupID: WorkspaceTabGroup],
                regions: [WorkspaceRegion],
                floatingWindows: [WorkspaceFloatingWindow] = [],
                splitFractions: WorkspaceSplitFractions = WorkspaceSplitFractions(),
                closedHistory: [WorkspaceClosedPanel] = []) {
        self.panels = panels
        self.groups = groups
        self.regions = WorkspaceRegionID.allCases.map { id in
            regions.first { $0.id == id } ?? WorkspaceRegion(id: id)
        }
        self.floatingWindows = floatingWindows
        self.splitFractions = splitFractions
        self.closedHistory = closedHistory
    }

    public func region(_ id: WorkspaceRegionID) -> WorkspaceRegion {
        regions.first { $0.id == id } ?? WorkspaceRegion(id: id)
    }

    public mutating func setRegion(_ region: WorkspaceRegion) {
        if let index = regions.firstIndex(where: { $0.id == region.id }) {
            regions[index] = region
        } else {
            regions.append(region)
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

    public func regionContaining(groupID: WorkspaceTabGroupID) -> WorkspaceRegionID? {
        regions.first { $0.groupIDs.contains(groupID) }?.id
    }

    public func floatingWindowContaining(groupID: WorkspaceTabGroupID) -> WorkspaceFloatingWindow? {
        floatingWindows.first { $0.groupID == groupID }
    }
}

public struct WorkspacePanelDescriptor {
    public var id: WorkspacePanelID
    public var title: String
    public var defaultRegion: WorkspaceRegionID
    public var isClosable: Bool
    public var isDraggable: Bool
    public var isCollapsible: Bool
    public var iconAssetKey: String?
    public let factory: () -> AnyView

    public init(id: WorkspacePanelID,
                title: String,
                defaultRegion: WorkspaceRegionID = .center,
                isClosable: Bool = true,
                isDraggable: Bool = true,
                isCollapsible: Bool = true,
                iconAssetKey: String? = nil,
                factory: @escaping () -> AnyView) {
        self.id = id
        self.title = title
        self.defaultRegion = defaultRegion
        self.isClosable = isClosable
        self.isDraggable = isDraggable
        self.isCollapsible = isCollapsible
        self.iconAssetKey = iconAssetKey
        self.factory = factory
    }

    public init<Content: View>(id: WorkspacePanelID,
                               title: String,
                               defaultRegion: WorkspaceRegionID = .center,
                               isClosable: Bool = true,
                               isDraggable: Bool = true,
                               isCollapsible: Bool = true,
                               iconAssetKey: String? = nil,
                               @ViewBuilder content: @escaping () -> Content) {
        self.init(id: id,
                  title: title,
                  defaultRegion: defaultRegion,
                  isClosable: isClosable,
                  isDraggable: isDraggable,
                  isCollapsible: isCollapsible,
                  iconAssetKey: iconAssetKey,
                  factory: { AnyView(content()) })
    }

    public var panel: WorkspacePanel {
        WorkspacePanel(id: id,
                       title: title,
                       isClosable: isClosable,
                       isDraggable: isDraggable,
                       isCollapsible: isCollapsible,
                       iconAssetKey: iconAssetKey)
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
        if byID[descriptor.id] == nil {
            order.append(descriptor.id)
        }
        byID[descriptor.id] = descriptor
    }

    public func updateDescriptor(id: WorkspacePanelID,
                                 _ update: (inout WorkspacePanelDescriptor) -> Void) {
        guard var descriptor = byID[id] else { return }
        update(&descriptor)
        byID[id] = descriptor
    }

    public func descriptor(for id: WorkspacePanelID) -> WorkspacePanelDescriptor? {
        byID[id]
    }

    public func make(_ id: WorkspacePanelID) -> AnyView {
        byID[id]?.factory() ?? AnyView(EmptyView())
    }

    public var ids: [WorkspacePanelID] { order }
    public var descriptors: [WorkspacePanelDescriptor] { order.compactMap { byID[$0] } }
}
