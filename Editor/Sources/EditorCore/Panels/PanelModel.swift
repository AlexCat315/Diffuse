import Foundation

public protocol PanelModel: Sendable {
    var id: String { get }
    var title: String { get }
}

public struct BasicPanelModel: PanelModel, Codable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct PanelRegistry: Sendable {
    private let panels: [String: BasicPanelModel]

    public init(panels: [BasicPanelModel]) {
        self.panels = Dictionary(uniqueKeysWithValues: panels.map { ($0.id, $0) })
    }

    public func allPanels() -> [BasicPanelModel] {
        panels.values.sorted { $0.id < $1.id }
    }

    public func panel(id: String) -> BasicPanelModel? {
        panels[id]
    }
}
