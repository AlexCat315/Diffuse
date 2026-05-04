import EditorCore
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import Foundation

enum EditorRootViewFactory {
    struct EditorShellState: Codable, Sendable {
        var workspaceMode: EditorWorkspaceMode
        var activeLayoutPreset: EditorLayoutPreset
        var themeMode: EditorThemeMode
        var language: EditorLanguage
        var vsyncMode: EditorVSyncMode
        var primarySelectBehavior: SelectionPrimaryModifierBehavior
        var schemaVersion: Int

        static let currentSchemaVersion = 7

        init(workspaceMode: EditorWorkspaceMode,
             activeLayoutPreset: EditorLayoutPreset,
             themeMode: EditorThemeMode = .dark,
             language: EditorLanguage = .system,
             vsyncMode: EditorVSyncMode = .enabled,
             primarySelectBehavior: SelectionPrimaryModifierBehavior = .subtract,
             schemaVersion: Int = currentSchemaVersion) {
            self.workspaceMode = workspaceMode
            self.activeLayoutPreset = activeLayoutPreset
            self.themeMode = themeMode
            self.language = language
            self.vsyncMode = vsyncMode
            self.primarySelectBehavior = primarySelectBehavior
            self.schemaVersion = schemaVersion
        }

        enum CodingKeys: String, CodingKey {
            case workspaceMode
            case activeLayoutPreset
            case themeMode
            case language
            case vsyncMode
            case primarySelectBehavior
            case schemaVersion
        }

        enum LegacyCodingKeys: String, CodingKey {
            case frameRateLimit
            case cmdSelectBehavior
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(workspaceMode, forKey: .workspaceMode)
            try values.encode(activeLayoutPreset, forKey: .activeLayoutPreset)
            try values.encode(themeMode, forKey: .themeMode)
            try values.encode(language, forKey: .language)
            try values.encode(vsyncMode, forKey: .vsyncMode)
            try values.encode(primarySelectBehavior, forKey: .primarySelectBehavior)
            try values.encode(schemaVersion, forKey: .schemaVersion)
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            workspaceMode = try values.decodeIfPresent(EditorWorkspaceMode.self, forKey: .workspaceMode) ?? .level
            activeLayoutPreset = try values.decodeIfPresent(EditorLayoutPreset.self, forKey: .activeLayoutPreset)
                ?? .default(for: workspaceMode)
            let decodedSchemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            if decodedSchemaVersion < 6 {
                themeMode = .dark
            } else {
                themeMode = try values.decodeIfPresent(EditorThemeMode.self, forKey: .themeMode) ?? .dark
            }
            language = try values.decodeIfPresent(EditorLanguage.self, forKey: .language) ?? .system
            let legacyValues = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if let decodedVSync = try values.decodeIfPresent(EditorVSyncMode.self, forKey: .vsyncMode) {
                vsyncMode = decodedVSync
            } else if let legacyLimit = try legacyValues.decodeIfPresent(String.self, forKey: .frameRateLimit) {
                vsyncMode = EditorVSyncMode(legacyFrameRateLimitRawValue: legacyLimit)
            } else {
                vsyncMode = .enabled
            }
            let decodedPrimarySelectBehavior = try values.decodeIfPresent(
                SelectionPrimaryModifierBehavior.self,
                forKey: .primarySelectBehavior
            )
            let legacyPrimarySelectBehavior = try legacyValues.decodeIfPresent(
                SelectionPrimaryModifierBehavior.self,
                forKey: .cmdSelectBehavior
            )
            primarySelectBehavior = decodedPrimarySelectBehavior ?? legacyPrimarySelectBehavior ?? .subtract
            schemaVersion = decodedSchemaVersion
        }
    }

    static func makeController(for mode: EditorWorkspaceMode,
                               preset: EditorLayoutPreset) -> DockController {
        // Try to restore saved layout, otherwise create default
        if let saved = loadSavedLayout(for: mode, preset: preset) {
            localizeDockTitles(in: saved)
            return saved
        }
        if mode == .level,
           preset == .levelDefault,
           let legacy = loadLegacySavedLayout() {
            localizeDockTitles(in: legacy)
            return legacy
        }
        return makeDefaultController(for: mode, preset: preset)
    }

    static func makeController(for mode: EditorWorkspaceMode) -> DockController {
        makeController(for: mode, preset: .default(for: mode))
    }

    static func makeController() -> DockController {
        makeController(for: .level)
    }

    static func makeDefaultController(for mode: EditorWorkspaceMode,
                                      preset: EditorLayoutPreset) -> DockController {
        let hierarchyTab = DockTab(userKey: "hierarchy", title: localizedPanelTitle(for: "hierarchy"))
        let inspectorTab = DockTab(userKey: "inspector", title: localizedPanelTitle(for: "inspector"))
        let viewportTab = DockTab(userKey: "viewport",
                                  title: localizedPanelTitle(for: "viewport"),
                                  isClosable: false)
        let consoleTab = DockTab(userKey: "console", title: localizedPanelTitle(for: "console"))
        let assetsTab = DockTab(userKey: "assets", title: localizedPanelTitle(for: "assets"))
        let intentTab = DockTab(userKey: "intent-input", title: localizedPanelTitle(for: "intent-input"))
        let confirmationTab = DockTab(userKey: "confirmation-host", title: localizedPanelTitle(for: "confirmation-host"))

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
            activeTabID: defaultBottomTabID(for: preset,
                                            assetsTab: assetsTab,
                                            consoleTab: consoleTab,
                                            intentTab: intentTab,
                                            confirmationTab: confirmationTab)
        )

        let fractions = defaultFractions(for: preset)

        let viewportAndInspector: DockLayoutNode = .split(
            id: DockNodeID(),
            axis: .horizontal,
            fraction: fractions.viewportAndInspector,
            first: viewportLeaf,
            second: inspectorLeaf
        )
        let topRow: DockLayoutNode = .split(
            id: DockNodeID(),
            axis: .horizontal,
            fraction: fractions.hierarchyAndMain,
            first: hierarchyLeaf,
            second: viewportAndInspector
        )
        let root: DockLayoutNode = .split(
            id: DockNodeID(),
            axis: .vertical,
            fraction: fractions.topAndBottom,
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

    static func loadLayoutPreset(into controller: DockController,
                                 for mode: EditorWorkspaceMode,
                                 preset: EditorLayoutPreset) {
        if let saved = loadSavedLayout(for: mode, preset: preset) {
            controller.load(saved.snapshot())
            localizeDockTitles(in: controller)
            return
        }
        let fallback = makeDefaultController(for: mode, preset: preset)
        controller.load(fallback.snapshot())
        localizeDockTitles(in: controller)
    }

    static func resetLayout(into controller: DockController,
                            for mode: EditorWorkspaceMode,
                            preset: EditorLayoutPreset) {
        let fallback = makeDefaultController(for: mode, preset: preset)
        controller.load(fallback.snapshot())
    }

    static func resetLayout(into controller: DockController,
                            for mode: EditorWorkspaceMode) {
        resetLayout(into: controller,
                    for: mode,
                    preset: .default(for: mode))
    }

    static func activateTab(_ userKey: String, in controller: DockController) {
        if let target = findTab(userKey, in: controller.root) {
            controller.apply(.setActive(node: target.leafID, tab: target.tabID))
            return
        }

        let tab = DockTab(userKey: userKey, title: localizedPanelTitle(for: userKey))
        let leafID = findBottomLeaf(in: controller.root) ?? firstTabsLeaf(in: controller.root)
        if let leafID {
            controller.apply(.insertTab(tab, into: leafID, at: Int.max))
            controller.apply(.setActive(node: leafID, tab: tab.id))
        }
    }

    static func openSettingsSatellite(in controller: DockController) {
        let settingsKey = "settings"

        // Settings is already detached; keep the existing satellite.
        if findTabInSatellites(settingsKey, in: controller.satellites) != nil {
            return
        }

        if let location = findTabLocation(settingsKey, in: controller.root) {
            if location.tabCount > 1 {
                controller.apply(.move(tabID: location.tabID,
                                       to: .splitEdge(target: location.leafID,
                                                      edge: .right)))
            }
            if let detached = findTab(settingsKey, in: controller.root) {
                controller.apply(.detach(leafID: detached.leafID))
            }
            return
        }

        activateTab(settingsKey, in: controller)
        if let inserted = findTabLocation(settingsKey, in: controller.root) {
            if inserted.tabCount > 1 {
                controller.apply(.move(tabID: inserted.tabID,
                                       to: .splitEdge(target: inserted.leafID,
                                                      edge: .right)))
            }
            if let detached = findTab(settingsKey, in: controller.root) {
                controller.apply(.detach(leafID: detached.leafID))
            }
        }
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

    private static func findTab(_ userKey: String,
                                in node: DockLayoutNode) -> (leafID: DockNodeID, tabID: DockTabID)? {
        switch node {
        case .empty:
            return nil
        case .tabs(let id, let tabs, _):
            guard let tab = tabs.first(where: { $0.userKey == userKey }) else { return nil }
            return (id, tab.id)
        case .split(_, _, _, let first, let second):
            return findTab(userKey, in: first) ?? findTab(userKey, in: second)
        }
    }

    private static func findTabLocation(_ userKey: String,
                                        in node: DockLayoutNode) -> (leafID: DockNodeID, tabID: DockTabID, tabCount: Int)? {
        switch node {
        case .empty:
            return nil
        case .tabs(let id, let tabs, _):
            guard let tab = tabs.first(where: { $0.userKey == userKey }) else { return nil }
            return (leafID: id, tabID: tab.id, tabCount: tabs.count)
        case .split(_, _, _, let first, let second):
            return findTabLocation(userKey, in: first) ?? findTabLocation(userKey, in: second)
        }
    }

    private static func findTabInSatellites(_ userKey: String,
                                            in satellites: [DockNodeID: DockLayoutNode]) -> (leafID: DockNodeID, tabID: DockTabID)? {
        for (leafID, node) in satellites {
            guard case .tabs(_, let tabs, _) = node,
                  let tab = tabs.first(where: { $0.userKey == userKey }) else {
                continue
            }
            return (leafID: leafID, tabID: tab.id)
        }
        return nil
    }

    private static func findBottomLeaf(in node: DockLayoutNode) -> DockNodeID? {
        switch node {
        case .empty:
            return nil
        case .tabs(let id, let tabs, _):
            let bottomKeys: Set<String> = ["assets", "console", "intent-input", "confirmation-host"]
            return tabs.contains(where: { bottomKeys.contains($0.userKey) }) ? id : nil
        case .split(_, _, _, let first, let second):
            return findBottomLeaf(in: second) ?? findBottomLeaf(in: first)
        }
    }

    private static func firstTabsLeaf(in node: DockLayoutNode) -> DockNodeID? {
        switch node {
        case .empty:
            return nil
        case .tabs(let id, _, _):
            return id
        case .split(_, _, _, let first, let second):
            return firstTabsLeaf(in: first) ?? firstTabsLeaf(in: second)
        }
    }

    static func localizeDockTitles(in controller: DockController) {
        let root = localizeDockTitles(in: controller.root)
        let satellites = controller.satellites.mapValues(localizeDockTitles(in:))
        let minimizedLeaves = controller.minimizedLeaves.mapValues { leaf in
            DockMinimizedLeaf(node: localizeDockTitles(in: leaf.node),
                              edge: leaf.edge)
        }
        controller.replace(root: root,
                           satellites: satellites,
                           satelliteOrder: controller.satelliteOrder,
                           minimizedLeaves: minimizedLeaves,
                           minimizedOrder: controller.minimizedOrder)
    }

    static func localizePanelTitles(in registry: PanelRegistry) {
        for id in registry.ids {
            registry.updateDescriptor(id: id) { descriptor in
                descriptor.title = localizedPanelTitle(for: descriptor.id)
            }
        }
    }

    private static func localizeDockTitles(in node: DockLayoutNode) -> DockLayoutNode {
        switch node {
        case .empty:
            return node
        case .tabs(let id, let tabs, let active):
            let localizedTabs = tabs.map { tab -> DockTab in
                var next = tab
                next.title = localizedPanelTitle(for: tab.userKey)
                return next
            }
            return .tabs(id: id, tabs: localizedTabs, activeTabID: active)
        case .split(let id, let axis, let fraction, let first, let second):
            return .split(id: id,
                          axis: axis,
                          fraction: fraction,
                          first: localizeDockTitles(in: first),
                          second: localizeDockTitles(in: second))
        }
    }

    private static func localizedPanelTitle(for userKey: String) -> String {
        switch userKey {
        case "hierarchy": return L("Hierarchy")
        case "inspector": return L("Inspector")
        case "viewport": return L("Viewport")
        case "console": return L("Console")
        case "assets": return L("Assets")
        case "intent-input": return L("AI Intent")
        case "confirmation-host": return L("Confirm")
        case "settings": return L("Settings")
        default: return userKey
        }
    }

    static func makeRegistry(app: EditorApplication) -> PanelRegistry {
        PanelRegistry([
            PanelDescriptor(id: "hierarchy",
                            title: localizedPanelTitle(for: "hierarchy"),
                            preferredRegion: .leadingSidebar) {
                HierarchyPanel(store: app.store, scene: app.scene)
            },
            PanelDescriptor(id: "inspector",
                            title: localizedPanelTitle(for: "inspector"),
                            preferredRegion: .trailingSidebar) {
                InspectorPanel(store: app.store, scene: app.scene)
            },
            PanelDescriptor(id: "viewport",
                            title: localizedPanelTitle(for: "viewport"),
                            closable: false,
                            preferredRegion: .center) {
                ViewportPanel(app: app, scene: app.scene)
            },
            PanelDescriptor(id: "console",
                            title: localizedPanelTitle(for: "console"),
                            preferredRegion: .bottomPanel) {
                ConsolePanel(store: app.store)
            },
            PanelDescriptor(id: "assets",
                            title: localizedPanelTitle(for: "assets"),
                            preferredRegion: .bottomPanel) {
                AssetBrowserPanel(app: app)
            },
            PanelDescriptor(id: "intent-input",
                            title: localizedPanelTitle(for: "intent-input"),
                            preferredRegion: .bottomPanel) {
                IntentInputPanel(app: app)
            },
            PanelDescriptor(id: "confirmation-host",
                            title: localizedPanelTitle(for: "confirmation-host"),
                            preferredRegion: .bottomPanel) {
                ConfirmationHostPanel(app: app)
            },
        ])
    }

    private static let layoutPersistenceKey = "editor_dock_layout_v2"
    private static let shellStatePersistenceKey = "editor_shell_state"

    private struct LayoutFractions {
        let hierarchyAndMain: Float
        let viewportAndInspector: Float
        let topAndBottom: Float
    }

    private static func defaultFractions(for preset: EditorLayoutPreset) -> LayoutFractions {
        switch preset {
        case .levelDefault:
            return LayoutFractions(hierarchyAndMain: 0.22,
                                   viewportAndInspector: 0.78,
                                   topAndBottom: 0.74)
        case .levelCinematics:
            return LayoutFractions(hierarchyAndMain: 0.18,
                                   viewportAndInspector: 0.80,
                                   topAndBottom: 0.68)
        case .modelingDefault:
            return LayoutFractions(hierarchyAndMain: 0.22,
                                   viewportAndInspector: 0.76,
                                   topAndBottom: 0.72)
        case .modelingSculpt:
            return LayoutFractions(hierarchyAndMain: 0.19,
                                   viewportAndInspector: 0.78,
                                   topAndBottom: 0.72)
        case .animationDefault:
            return LayoutFractions(hierarchyAndMain: 0.20,
                                   viewportAndInspector: 0.76,
                                   topAndBottom: 0.66)
        case .animationSequencer:
            return LayoutFractions(hierarchyAndMain: 0.18,
                                   viewportAndInspector: 0.74,
                                   topAndBottom: 0.58)
        }
    }

    private static func defaultBottomTabID(for preset: EditorLayoutPreset,
                                           assetsTab: DockTab,
                                           consoleTab: DockTab,
                                           intentTab: DockTab,
                                           confirmationTab: DockTab) -> DockTabID {
        switch preset {
        case .levelDefault, .levelCinematics:
            return assetsTab.id
        case .modelingDefault, .modelingSculpt:
            return consoleTab.id
        case .animationDefault, .animationSequencer:
            return intentTab.id
        }
    }

    private static func layoutPersistenceKey(for mode: EditorWorkspaceMode,
                                             preset: EditorLayoutPreset) -> String {
        "\(layoutPersistenceKey)_\(mode.rawValue)_\(preset.rawValue)"
    }

    static func saveDockLayout(_ controller: DockController,
                               for mode: EditorWorkspaceMode,
                               preset: EditorLayoutPreset) {
        // Ensure viewport is not detached; if it is, redock it to center before saving
        if let centerLeaf = findCenterLeaf(controller.root) {
            ensureViewportDocked(in: controller, to: centerLeaf.id)
        }

        // Create a snapshot of the current layout state
        let snapshot = DockLayoutSnapshot(
            root: controller.root,
            satellites: controller.satellites,
            satelliteOrder: controller.satelliteOrder,
            minimizedLeaves: controller.minimizedLeaves,
            minimizedOrder: controller.minimizedOrder
        )

        // Encode and save to disk
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(snapshot)
            if let layoutDir = getLayoutPersistenceDirectory() {
                let layoutPath = layoutDir.appendingPathComponent(
                    layoutPersistenceKey(for: mode, preset: preset) + ".json"
                )
                try data.write(to: layoutPath)
            }
        } catch {
            fputs("[EditorRootViewFactory] failed to save dock layout: \(error)\n", stderr)
        }
    }

    static func saveDockLayout(_ controller: DockController) {
        saveDockLayout(controller,
                       for: .level,
                       preset: .levelDefault)
    }

    private static func loadSavedLayout(for mode: EditorWorkspaceMode,
                                        preset: EditorLayoutPreset) -> DockController? {
        guard let layoutDir = getLayoutPersistenceDirectory() else { return nil }
        let layoutPath = layoutDir.appendingPathComponent(
            layoutPersistenceKey(for: mode, preset: preset) + ".json"
        )
        
        guard FileManager.default.fileExists(atPath: layoutPath.path) else { return nil }

        do {
            let data = try Data(contentsOf: layoutPath)
            let decoder = JSONDecoder()
            var snapshot = try decoder.decode(DockLayoutSnapshot.self, from: data)
            snapshot.root = sanitizeDockLayout(snapshot.root)
            guard !isEmptyDockLayout(snapshot.root) else { return nil }
            snapshot.satellites = sanitizeSatellites(snapshot.satellites)
            snapshot.satelliteOrder = snapshot.satelliteOrder.filter { snapshot.satellites[$0] != nil }
            snapshot.minimizedLeaves = sanitizeMinimizedLeaves(snapshot.minimizedLeaves)
            snapshot.minimizedOrder = snapshot.minimizedOrder.filter { snapshot.minimizedLeaves[$0] != nil }
            let controller = DockController(root: snapshot.root)
            controller.load(snapshot)
            return controller
        } catch {
            fputs("[EditorRootViewFactory] failed to load dock layout: \(error)\n", stderr)
            return nil
        }
    }

    private static func loadLegacySavedLayout() -> DockController? {
        guard let layoutDir = getLayoutPersistenceDirectory() else { return nil }
        let layoutPath = layoutDir.appendingPathComponent(layoutPersistenceKey + ".json")
        guard FileManager.default.fileExists(atPath: layoutPath.path) else { return nil }

        do {
            let data = try Data(contentsOf: layoutPath)
            let decoder = JSONDecoder()
            var snapshot = try decoder.decode(DockLayoutSnapshot.self, from: data)
            snapshot.root = sanitizeDockLayout(snapshot.root)
            guard !isEmptyDockLayout(snapshot.root) else { return nil }
            snapshot.satellites = sanitizeSatellites(snapshot.satellites)
            snapshot.satelliteOrder = snapshot.satelliteOrder.filter { snapshot.satellites[$0] != nil }
            snapshot.minimizedLeaves = sanitizeMinimizedLeaves(snapshot.minimizedLeaves)
            snapshot.minimizedOrder = snapshot.minimizedOrder.filter { snapshot.minimizedLeaves[$0] != nil }
            let controller = DockController(root: snapshot.root)
            controller.load(snapshot)
            return controller
        } catch {
            fputs("[EditorRootViewFactory] failed to load legacy dock layout: \(error)\n", stderr)
            return nil
        }
    }

    private static func sanitizeDockLayout(_ node: DockLayoutNode) -> DockLayoutNode {
        switch node {
        case .empty:
            return node
        case .tabs(let id, let tabs, let active):
            let filtered = tabs.filter { $0.userKey != "settings" }
            guard !filtered.isEmpty else { return .empty(id: id) }
            let nextActive = active.flatMap { activeID in
                filtered.contains(where: { $0.id == activeID }) ? activeID : nil
            } ?? filtered.first?.id
            return .tabs(id: id, tabs: filtered, activeTabID: nextActive)
        case .split(let id, let axis, let fraction, let first, let second):
            let clamped = max(0.05, min(0.95, fraction))
            let sanitizedFirst = sanitizeDockLayout(first)
            let sanitizedSecond = sanitizeDockLayout(second)
            if case .empty = sanitizedFirst { return sanitizedSecond }
            if case .empty = sanitizedSecond { return sanitizedFirst }
            return .split(id: id,
                          axis: axis,
                          fraction: clamped,
                          first: sanitizedFirst,
                          second: sanitizedSecond)
        }
    }

    private static func sanitizeSatellites(_ satellites: [DockNodeID: DockLayoutNode]) -> [DockNodeID: DockLayoutNode] {
        satellites.compactMapValues { node in
            let sanitized = sanitizeDockLayout(node)
            if case .empty = sanitized {
                return nil
            }
            return sanitized
        }
    }

    private static func sanitizeMinimizedLeaves(_ leaves: [DockNodeID: DockMinimizedLeaf]) -> [DockNodeID: DockMinimizedLeaf] {
        leaves.compactMapValues { leaf in
            let sanitized = sanitizeDockLayout(leaf.node)
            guard case .tabs = sanitized else { return nil }
            return DockMinimizedLeaf(node: sanitized, edge: leaf.edge)
        }
    }

    private static func isEmptyDockLayout(_ node: DockLayoutNode) -> Bool {
        if case .empty = node { return true }
        return false
    }

    static func saveShellState(mode: EditorWorkspaceMode,
                               preset: EditorLayoutPreset,
                               themeMode: EditorThemeMode,
                               language: EditorLanguage,
                               vsyncMode: EditorVSyncMode,
                               primarySelectBehavior: SelectionPrimaryModifierBehavior = .subtract) {
        guard let layoutDir = getLayoutPersistenceDirectory() else { return }
        let shell = EditorShellState(workspaceMode: mode,
                                     activeLayoutPreset: preset,
                                     themeMode: themeMode,
                                     language: language,
                                     vsyncMode: vsyncMode,
                                     primarySelectBehavior: primarySelectBehavior)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(shell)
            let path = layoutDir.appendingPathComponent(shellStatePersistenceKey + ".json")
            try data.write(to: path)
        } catch {
            fputs("[EditorRootViewFactory] failed to save shell state: \(error)\n", stderr)
        }
    }

    static func loadShellState() -> EditorShellState? {
        guard let layoutDir = getLayoutPersistenceDirectory() else { return nil }
        let path = layoutDir.appendingPathComponent(shellStatePersistenceKey + ".json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }

        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            var shell = try decoder.decode(EditorShellState.self, from: data)
            if shell.activeLayoutPreset.mode != shell.workspaceMode {
                shell.activeLayoutPreset = .default(for: shell.workspaceMode)
            }
            return shell
        } catch {
            fputs("[EditorRootViewFactory] failed to load shell state: \(error)\n", stderr)
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

        for (leafID, minimized) in controller.minimizedLeaves {
            if case .tabs(_, let tabs, _) = minimized.node,
               tabs.contains(where: { $0.userKey == viewportKey }) {
                controller.apply(.restoreMinimizedLeaf(leafID))
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
