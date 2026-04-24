import EditorCore
import GuavaUIApp
import GuavaUICompose
import Foundation

/// 编辑器根视图。装配 `DockController` + `PanelRegistry` + 一个三列 `PanelWorkspace`。
struct EditorRootView: View {
    let app: EditorApplication
    let controller: DockController
    let registry: PanelRegistry

    var body: some View {
        PanelWorkspace(controller: controller,
                       registry: registry)
            .appearance(.dark)
    }
}

@MainActor
enum EditorRootViewFactory {
    static func makeController() -> DockController {
        // Try to restore saved layout, otherwise create default
        if let saved = loadSavedLayout() {
            return saved
        }
        return makeDefaultController()
    }

    static func makeDefaultController() -> DockController {
        let hierarchyTab = DockTab(userKey: "hierarchy", title: "Hierarchy")
        let inspectorTab = DockTab(userKey: "inspector", title: "Inspector")
        let viewportTab = DockTab(userKey: "viewport",
                                  title: "Viewport",
                                  isClosable: false)
        let consoleTab = DockTab(userKey: "console", title: "Console")
        let assetsTab = DockTab(userKey: "assets", title: "Assets")
        let intentTab = DockTab(userKey: "intent-input", title: "AI Intent")
        let confirmationTab = DockTab(userKey: "confirmation-host", title: "Confirm")

        let hierarchyLeaf: DockLayoutNode = .tabs(
            id: DockNodeID(),
            tabs: [hierarchyTab],
            activeTabID: hierarchyTab.id
        )
        let inspectorLeaf: DockLayoutNode = .tabs(
            id: DockNodeID(),
            tabs: [inspectorTab],
            activeTabID: inspectorTab.id
        )
        let viewportLeaf: DockLayoutNode = .tabs(
            id: DockNodeID(),
            tabs: [viewportTab],
            activeTabID: viewportTab.id
        )
        let bottomLeaf: DockLayoutNode = .tabs(
            id: DockNodeID(),
            tabs: [assetsTab, consoleTab, intentTab, confirmationTab],
            activeTabID: assetsTab.id
        )

        let viewportAndInspector: DockLayoutNode = .split(
            id: DockNodeID(),
            axis: .horizontal,
            fraction: 55.0 / 75.0,
            first: viewportLeaf,
            second: inspectorLeaf
        )
        let topRow: DockLayoutNode = .split(
            id: DockNodeID(),
            axis: .horizontal,
            fraction: 15.0 / 90.0,
            first: hierarchyLeaf,
            second: viewportAndInspector
        )
        let root: DockLayoutNode = .split(
            id: DockNodeID(),
            axis: .vertical,
            fraction: 0.7,
            first: topRow,
            second: bottomLeaf
        )
        let controller = DockController(root: root)
        let regionByKey: [String: PanelWorkspaceRegion] = [
            "hierarchy": .leadingSidebar,
            "viewport": .center,
            "inspector": .trailingSidebar,
            "console": .bottomPanel,
            "assets": .bottomPanel,
            "intent-input": .bottomPanel,
            "confirmation-host": .bottomPanel,
        ]
        controller.onAllowDrop = { [regionByKey] request in
            guard case .splitEdge(let targetID, let edge) = request.target else {
                return true
            }
            guard let targetRegion = regionOfLeaf(id: targetID,
                                                  in: controller.root,
                                                  regionByKey: regionByKey) else {
                return true
            }
            return allowsSplitEdge(in: targetRegion, edge: edge)
        }
        return controller
    }

    private static func allowsSplitEdge(in region: PanelWorkspaceRegion,
                                        edge: DockEdge) -> Bool {
        switch region {
        case .center:
            return true
        case .leadingSidebar, .trailingSidebar:
            return edge == .top || edge == .bottom
        case .bottomPanel:
            return edge == .left || edge == .right
        }
    }

    private static func regionOfLeaf(id: DockNodeID,
                                     in node: DockLayoutNode,
                                     regionByKey: [String: PanelWorkspaceRegion]) -> PanelWorkspaceRegion? {
        guard let found = findNode(id, in: node) else { return nil }
        switch found {
        case .empty:
            return .center
        case .tabs(_, let tabs, _):
            guard let first = tabs.first else { return .center }
            return regionByKey[first.userKey] ?? .center
        case .split:
            return nil
        }
    }

    private static func findNode(_ id: DockNodeID,
                                 in node: DockLayoutNode) -> DockLayoutNode? {
        if node.id == id { return node }
        guard case .split(_, _, _, let first, let second) = node else {
            return nil
        }
        return findNode(id, in: first) ?? findNode(id, in: second)
    }

    static func makeRegistry(app: EditorApplication) -> PanelRegistry {
        PanelRegistry([
            PanelDescriptor(id: "hierarchy",
                            title: "Hierarchy",
                            preferredRegion: .leadingSidebar) {
                HierarchyPanel(store: app.store, scene: app.scene)
            },
            PanelDescriptor(id: "inspector",
                            title: "Inspector",
                            preferredRegion: .trailingSidebar) {
                InspectorPanel(store: app.store, scene: app.scene)
            },
            PanelDescriptor(id: "viewport",
                            title: "Viewport",
                            closable: false,
                            preferredRegion: .center) {
                ViewportPanel(app: app, scene: app.scene)
            },
            PanelDescriptor(id: "console",
                            title: "Console",
                            preferredRegion: .bottomPanel) {
                ConsolePanel(store: app.store)
            },
            PanelDescriptor(id: "assets",
                            title: "Assets",
                            preferredRegion: .bottomPanel) {
                AssetBrowserPanel(app: app)
            },
            PanelDescriptor(id: "intent-input",
                            title: "AI Intent",
                            preferredRegion: .bottomPanel) {
                IntentInputPanel(app: app)
            },
            PanelDescriptor(id: "confirmation-host",
                            title: "Confirm",
                            preferredRegion: .bottomPanel) {
                ConfirmationHostPanel(app: app)
            },
        ])
    }

    private static let layoutPersistenceKey = "editor_dock_layout"

    static func saveDockLayout(_ controller: DockController) {
        // Ensure viewport is not detached; if it is, redock it to center before saving
        if let centerLeaf = findCenterLeaf(controller.root) {
            ensureViewportDocked(in: controller, to: centerLeaf.id)
        }

        // Create a snapshot of the current layout state
        let snapshot = DockLayoutSnapshot(
            root: controller.root,
            satellites: controller.satellites,
            satelliteOrder: controller.satelliteOrder
        )

        // Encode and save to disk
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(snapshot)
            if let layoutDir = getLayoutPersistenceDirectory() {
                let layoutPath = layoutDir.appendingPathComponent(layoutPersistenceKey + ".json")
                try data.write(to: layoutPath)
            }
        } catch {
            fputs("[EditorRootViewFactory] failed to save dock layout: \(error)\n", stderr)
        }
    }

    private static func loadSavedLayout() -> DockController? {
        guard let layoutDir = getLayoutPersistenceDirectory() else { return nil }
        let layoutPath = layoutDir.appendingPathComponent(layoutPersistenceKey + ".json")
        
        guard FileManager.default.fileExists(atPath: layoutPath.path) else { return nil }

        do {
            let data = try Data(contentsOf: layoutPath)
            let decoder = JSONDecoder()
            let snapshot = try decoder.decode(DockLayoutSnapshot.self, from: data)
            let controller = DockController(root: snapshot.root)
            controller.load(snapshot)
            return controller
        } catch {
            fputs("[EditorRootViewFactory] failed to load dock layout: \(error)\n", stderr)
            return nil
        }
    }

    private static func getLayoutPersistenceDirectory() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask).first else {
            return nil
        }
        let guavaDir = appSupport.appendingPathComponent("Guava")
        try? FileManager.default.createDirectory(at: guavaDir, withIntermediateDirectories: true)
        return guavaDir
    }

    /// If viewport tab is in satellites, redock it to the center leaf
    private static func ensureViewportDocked(in controller: DockController, to leafID: DockNodeID) {
        let viewportKey = "viewport"
        
        // Check if viewport is in satellites
        for (satelliteID, satellite) in controller.satellites {
            if case .tabs(_, let tabs, _) = satellite,
               tabs.contains(where: { $0.userKey == viewportKey }) {
                // Found viewport in a satellite, redock it
                let viewportTab = tabs.first { $0.userKey == viewportKey }!
                controller.apply(.insertTab(viewportTab, into: leafID, at: 0))
                controller.apply(.closeSatellite(satelliteID))
                return
            }
        }
    }

    private static func findCenterLeaf(_ node: DockLayoutNode) -> DockLayoutNode? {
        switch node {
        case .empty:
            return node
        case .tabs:
            return node
        case .split(_, _, _, let first, let second):
            if let found = findCenterLeaf(first) { return found }
            return findCenterLeaf(second)
        }
    }
}
