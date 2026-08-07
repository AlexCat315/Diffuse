import EditorCore
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
}
