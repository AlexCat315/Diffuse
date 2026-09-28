import EditorCore
import EngineKernel
import Testing
@testable import EditorApp

@Suite("Editor panel workflows")
struct EditorPanelWorkflowTests {
    private var hierarchy: [EditorSceneNode] {
        [
            EditorSceneNode(id: 1, name: "World", kind: "Group", children: [
                EditorSceneNode(id: 2, name: "Player Camera", kind: "Camera", children: []),
                EditorSceneNode(id: 3, name: "Player", kind: "Mesh", children: [
                    EditorSceneNode(id: 4, name: "Weapon", kind: "Mesh", children: []),
                ]),
            ]),
            EditorSceneNode(id: 5, name: "Key Light", kind: "Light", children: []),
        ]
    }

    @Test("hierarchy search is deterministic and navigation wraps")
    func hierarchySearchNavigation() {
        #expect(HierarchyPanelModel.allEntityIDs(in: hierarchy) == [1, 2, 3, 4, 5])
        let matches = HierarchyPanelModel.matchingEntityIDs(in: hierarchy, query: " PLAYER ")
        #expect(matches == [2, 3])
        #expect(HierarchyPanelModel.searchDestination(in: matches,
                                                      currentID: nil,
                                                      direction: .next) == 2)
        #expect(HierarchyPanelModel.searchDestination(in: matches,
                                                      currentID: 3,
                                                      direction: .next) == 2)
        #expect(HierarchyPanelModel.searchDestination(in: matches,
                                                      currentID: 2,
                                                      direction: .previous) == 3)
    }

    @Test("hierarchy relationship helpers return ancestors and complete descendants")
    func hierarchyRelationships() {
        #expect(HierarchyPanelModel.ancestorIDs(of: 4, in: hierarchy) == [1, 3])
        #expect(HierarchyPanelModel.ancestorIDs(of: 1, in: hierarchy).isEmpty)
        #expect(HierarchyPanelModel.descendantIDs(of: [3], in: hierarchy) == [4])
        #expect(HierarchyPanelModel.descendantIDs(of: [1, 3],
                                                 in: hierarchy,
                                                 includesSelection: true) == [1, 2, 3, 4])
    }

    @Test("move-to-root is disabled when selection is already covered by a selected ancestor")
    func hierarchyMoveToRootAvailability() {
        #expect(!HierarchyPanelModel.canMoveSelectionToRoot([], in: hierarchy))
        #expect(!HierarchyPanelModel.canMoveSelectionToRoot([1], in: hierarchy))
        #expect(HierarchyPanelModel.canMoveSelectionToRoot([3], in: hierarchy))
        #expect(!HierarchyPanelModel.canMoveSelectionToRoot([1, 3], in: hierarchy))
        #expect(HierarchyPanelModel.canMoveSelectionToRoot([3, 4], in: hierarchy))
        #expect(HierarchyPanelModel.canMoveSelectionToRoot([2, 3], in: hierarchy))
    }

    @Test("hierarchy drag destinations preserve sibling order and reject cycles")
    func hierarchyDropDestinations() throws {
        #expect(HierarchyPanelModel.dropDestination(for: 3,
                                                     position: .before,
                                                     in: hierarchy)
                == HierarchyDropDestination(parentID: 1, index: 1))
        #expect(HierarchyPanelModel.dropDestination(for: 3,
                                                     position: .inside,
                                                     in: hierarchy)
                == HierarchyDropDestination(parentID: 3, index: 1))
        #expect(HierarchyPanelModel.dropDestination(for: 3,
                                                     position: .after,
                                                     in: hierarchy)
                == HierarchyDropDestination(parentID: 1, index: 2))
        #expect(HierarchyPanelModel.dropDestination(for: 999,
                                                     position: .inside,
                                                     in: hierarchy) == nil)

        #expect(!HierarchyPanelModel.canDrop(entityID: 3,
                                             on: 4,
                                             position: .inside,
                                             in: hierarchy))
        #expect(!HierarchyPanelModel.canDrop(entityID: 1,
                                             on: 1,
                                             position: .after,
                                             in: hierarchy))
        #expect(HierarchyPanelModel.canDrop(entityID: 4,
                                            on: 2,
                                            position: .before,
                                            in: hierarchy))
    }

    @Test("console filtering combines severity and case-insensitive text search")
    func consoleFiltering() {
        let entries = [
            EditorConsoleEntry(id: 1, severity: .info, message: "Imported castle.glb"),
            EditorConsoleEntry(id: 2, severity: .warning, message: "Missing material",
                               detail: "Castle roof uses fallback"),
            EditorConsoleEntry(id: 3, severity: .error, message: "Build failed",
                               detail: "Shader compiler exited"),
        ]

        let warnings = ConsoleEntryFilter.filter(entries,
                                                 severities: [.warning],
                                                 query: "CASTLE")
        #expect(warnings.map(\.id) == [2])

        let diagnostics = ConsoleEntryFilter.filter(entries,
                                                    severities: [.warning, .error],
                                                    query: "")
        #expect(diagnostics.map(\.id) == [2, 3])

        let detailMatch = ConsoleEntryFilter.filter(entries,
                                                    severities: Set(EditorConsoleSeverity.allCases),
                                                    query: "roof uses")
        #expect(detailMatch.map(\.id) == [2])
    }

    @Test("console copy keeps severity, message, multiline detail, and ordering")
    func consoleExport() {
        let entries = [
            EditorConsoleEntry(id: 1, severity: .warning, message: "Missing material",
                               detail: "surface 2\nusing fallback"),
            EditorConsoleEntry(id: 2, severity: .error, message: "Build failed"),
        ]

        #expect(ConsoleEntryExport.formatted(entries)
                == "[WARNING] Missing material\nsurface 2\nusing fallback\n[ERROR] Build failed")
    }

    @Test("console follow offset moves to the tail without scrolling past it")
    func consoleFollowGeometry() {
        #expect(ConsoleScrollGeometry.bottomOffset(currentOffset: 15,
                                                   anchorMaxY: 260,
                                                   viewportMaxY: 200) == 75)
        #expect(ConsoleScrollGeometry.bottomOffset(currentOffset: 15,
                                                   anchorMaxY: 190,
                                                   viewportMaxY: 200) == 15)
    }

    @Test("inspector search matches section titles, field labels, and current values")
    func inspectorFiltering() {
        let sections = [
            EditorInspectorSection(
                id: "transform",
                title: "Transform",
                fields: [
                    EditorInspectorField(id: "position", label: "Position", value: .readOnly("0, 0, 0")),
                    EditorInspectorField(id: "rotation", label: "Rotation", value: .readOnly("0, 0, 0")),
                ]
            ),
            EditorInspectorSection(
                id: "light",
                title: "Light",
                fields: [
                    EditorInspectorField(id: "intensity", label: "Intensity", value: .readOnly("3")),
                ]
            ),
        ]

        let wholeSection = InspectorSectionFilter.filter(sections, query: " transform ")
        #expect(wholeSection.count == 1)
        #expect(wholeSection.first?.fields.count == 2)

        let oneField = InspectorSectionFilter.filter(sections, query: "ROTATION")
        #expect(oneField.map(\.id) == ["transform"])
        #expect(oneField.first?.fields.map(\.id) == ["rotation"])

        let valueMatch = InspectorSectionFilter.filter(sections, query: "3")
        #expect(valueMatch.map(\.id) == ["light"])
        #expect(valueMatch.first?.fields.map(\.id) == ["intensity"])

        #expect(InspectorSectionFilter.filter(sections, query: "missing").isEmpty)
    }

    @Test("inspector component picker searches names, identifiers, and categories")
    func inspectorComponentFiltering() {
        let kinds = EditorComponentKind.allCases

        #expect(InspectorComponentFilter.filter(kinds, query: "audioSource") == [.audioSource])
        #expect(InspectorComponentFilter.filter(kinds, query: "rigid body") == [.rigidBody])

        let physics = InspectorComponentFilter.filter(kinds, query: "physics")
        #expect(physics.contains(.rigidBody))
        #expect(physics.contains(.collider))
        #expect(!physics.contains(.audioSource))

        let rendering = InspectorComponentFilter.filter(kinds, query: "rendering")
        #expect(rendering.contains(.camera))
        #expect(rendering.contains(.particleEmitter))
    }

    @Test("AI settings drafts use provider defaults and never carry a secret across providers")
    func aiSettingsDraftProviderSwitching() {
        var draft = EditorAISettingsDraft(settings: .default)
        #expect(draft.provider == .none)
        #expect(draft.model.isEmpty)

        draft.apiKey = "secret-for-openai"
        draft.select(.openai)
        #expect(draft.model == EditorAIProvider.openai.defaultModel)
        #expect(draft.apiKey.isEmpty)

        draft.apiKey = "openai-secret"
        draft.select(.openai)
        #expect(draft.apiKey == "openai-secret")

        draft.model = "custom-compatible-model"
        draft.select(.deepseek)
        #expect(draft.model == "custom-compatible-model")
        #expect(draft.apiKey.isEmpty)

        draft.model = EditorAIProvider.deepseek.defaultModel
        draft.select(.anthropic)
        #expect(draft.model == EditorAIProvider.anthropic.defaultModel)
    }

    @Test("asset browser ordering keeps filters and sort modes deterministic")
    func assetBrowserOrdering() {
        let assets = [
            EditorAsset(id: "z-mesh", name: "zebra", relativePath: "Models/zebra.glb",
                        absolutePath: "/tmp/zebra.glb", kind: .glb, meshIndex: 2),
            EditorAsset(id: "a-texture", name: "Apple", relativePath: "Textures/apple.png",
                        absolutePath: "/tmp/apple.png", kind: .png, meshIndex: 0),
            EditorAsset(id: "a-mesh", name: "apple", relativePath: "Models/apple.obj",
                        absolutePath: "/tmp/apple.obj", kind: .obj, meshIndex: 3),
        ]

        #expect(AssetBrowserOrdering.filter(assets, category: .meshes).map(\.id) == ["z-mesh", "a-mesh"])
        #expect(AssetBrowserOrdering.filter(assets, category: .textures).map(\.id) == ["a-texture"])
        #expect(AssetBrowserOrdering.sort(assets, mode: .nameAscending).map(\.id)
                == ["a-mesh", "a-texture", "z-mesh"])
        #expect(AssetBrowserOrdering.sort(assets, mode: .nameDescending).map(\.id)
                == ["z-mesh", "a-texture", "a-mesh"])
        #expect(AssetBrowserOrdering.sort(assets, mode: .type).map(\.id)
                == ["z-mesh", "a-mesh", "a-texture"])
    }

    @Test("asset browser ordering breaks case-only ties consistently")
    func assetBrowserAssetTieOrdering() {
        let assets = [
            EditorAsset(id: "lower", name: "tree", relativePath: "Models/tree.obj",
                        absolutePath: "/tmp/tree.obj", kind: .obj, meshIndex: 1),
            EditorAsset(id: "upper", name: "Tree", relativePath: "Models/Tree.obj",
                        absolutePath: "/tmp/Tree.obj", kind: .obj, meshIndex: 2),
        ]

        #expect(AssetBrowserOrdering.sort(assets, mode: .nameAscending).map(\.id)
                == ["upper", "lower"])
        #expect(AssetBrowserOrdering.sort(assets, mode: .nameDescending).map(\.id)
                == ["lower", "upper"])
        #expect(AssetBrowserOrdering.sort(Array(assets.reversed()), mode: .nameAscending).map(\.id)
                == ["upper", "lower"])
    }

    @Test("asset browser selection supports range and modifier toggles")
    func assetBrowserSelection() {
        let visibleIDs = ["a", "b", "c", "d", "e"]
        var selection = AssetBrowserSelectionModel()

        selection.select("b", in: visibleIDs)
        selection.select("d", in: visibleIDs, modifiers: .shift)
        #expect(selection.selectedIDs == ["b", "c", "d"])

        selection.select("c", in: visibleIDs, modifiers: .gui)
        #expect(selection.selectedIDs == ["b", "d"])

        selection.select("e", in: visibleIDs, modifiers: [.gui, .shift])
        #expect(selection.selectedIDs == ["b", "c", "d", "e"])
        selection.selectAll(in: ["a", "e"])
        #expect(selection.selectedIDs == ["a", "e"])
        selection.clear()
        #expect(selection.selectedIDs.isEmpty)
    }

    @Test("asset browser keyboard navigation stays within visible results")
    func assetBrowserKeyboardNavigation() {
        let visibleIDs = ["a", "b", "c"]
        #expect(AssetBrowserSelectionModel.adjacentAssetID(from: nil,
                                                            in: visibleIDs,
                                                            direction: 1) == "a")
        #expect(AssetBrowserSelectionModel.adjacentAssetID(from: "b",
                                                            in: visibleIDs,
                                                            direction: -1) == "a")
        #expect(AssetBrowserSelectionModel.adjacentAssetID(from: "c",
                                                            in: visibleIDs,
                                                            direction: 1) == nil)
        #expect(AssetBrowserSelectionModel.adjacentAssetID(from: nil,
                                                            in: visibleIDs,
                                                            direction: -1) == "c")
    }

    @Test("asset browser folders show only immediate children and direct assets")
    func assetBrowserFolderListing() {
        let assets = [
            EditorAsset(id: "hero", name: "Hero", relativePath: "Models/Characters/Hero.glb",
                        absolutePath: "/tmp/Hero.glb", kind: .glb, meshIndex: 1),
            EditorAsset(id: "crate", name: "Crate", relativePath: "Models/Props/Crate.obj",
                        absolutePath: "/tmp/Crate.obj", kind: .obj, meshIndex: 2),
            EditorAsset(id: "wood", name: "Wood", relativePath: "Textures/Wood.png",
                        absolutePath: "/tmp/Wood.png", kind: .png, meshIndex: 0),
            EditorAsset(id: "root", name: "Backdrop", relativePath: "Backdrop.png",
                        absolutePath: "/tmp/Backdrop.png", kind: .png, meshIndex: 0),
        ]

        let root = AssetFolderListing.make(folder: "", from: assets)
        #expect(root.folders.map(\.name) == ["Models", "Textures"])
        #expect(root.assets.map(\.id) == ["root"])

        let models = AssetFolderListing.make(folder: "Models", from: assets)
        #expect(models.folders.map(\.name) == ["Characters", "Props"])
        #expect(models.assets.isEmpty)

        let props = AssetFolderListing.make(folder: "Models/Props", from: assets)
        #expect(props.folders.isEmpty)
        #expect(props.assets.map(\.id) == ["crate"])
    }

    @Test("asset browser folder ordering resolves case-only ties deterministically")
    func assetBrowserFolderTieOrdering() {
        let assets = [
            EditorAsset(id: "lower", name: "b", relativePath: "models/b.obj",
                        absolutePath: "/tmp/b.obj", kind: .obj, meshIndex: 1),
            EditorAsset(id: "upper", name: "a", relativePath: "Models/a.obj",
                        absolutePath: "/tmp/a.obj", kind: .obj, meshIndex: 2),
        ]

        #expect(AssetFolderListing.make(folder: "", from: assets).folders.map(\.name)
                == ["Models", "models"])
    }
}
