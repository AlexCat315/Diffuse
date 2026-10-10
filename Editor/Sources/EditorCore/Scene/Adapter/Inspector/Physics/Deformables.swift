import SceneRuntime

extension EditorSceneAdapter {
    // Authored controls come from the schema. These renderers only append
    // computed/resource diagnostics, which never enter component documents.
    func softBodySection(for entity: EntityID) -> EditorInspectorSection? {
        guard let schema = scene.componentRegistry["softBody"],
              var section = registryInspectorSection(schema, for: entity) else { return nil }
        let state = scene.softBodyStateFrame.states[entity]
        section.fields += [
            EditorInspectorField(id: "soft-body-streamed-vertices", label: L("Streamed Vertices"),
                                 value: .readOnly(String(state?.positions.count ?? 0))),
            EditorInspectorField(id: "soft-body-sleeping", label: L("Sleeping"),
                                 value: .readOnly((state?.isSleeping ?? false) ? L("Yes") : L("No"))),
        ]
        return section
    }

    func clothSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let schema = scene.componentRegistry["cloth"],
              var section = registryInspectorSection(schema, for: entity),
              let cloth = scene.component(Cloth.self, for: entity) else { return nil }
        section.fields.append(EditorInspectorField(id: "cloth-vertex-count", label: L("Vertices"),
                                                  value: .readOnly(String(cloth.vertexCount))))
        return section
    }

    func softBodyMeshSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let schema = scene.componentRegistry["softBodyMesh"],
              var section = registryInspectorSection(schema, for: entity),
              let mesh = scene.component(SoftBodyMesh.self, for: entity) else { return nil }
        let geometry = scene.resource(MeshColliderGeometryResource.self)?.geometry(for: mesh.resourceID)
        section.fields += [
            EditorInspectorField(id: "soft-body-mesh-vertices", label: L("Vertices"),
                                 value: .readOnly(String(geometry?.positions.count ?? 0))),
            EditorInspectorField(id: "soft-body-mesh-triangles", label: L("Triangles"),
                                 value: .readOnly(String(geometry?.triangleCount ?? 0))),
            EditorInspectorField(id: "soft-body-mesh-tetrahedra", label: L("Tetrahedra"),
                                 value: .readOnly(String(geometry?.tetrahedronCount ?? 0))),
            EditorInspectorField(id: "soft-body-mesh-revision", label: L("Geometry Revision"),
                                 value: .readOnly(geometry.map { String($0.revision) } ?? L("Missing"))),
        ]
        return section
    }
}
