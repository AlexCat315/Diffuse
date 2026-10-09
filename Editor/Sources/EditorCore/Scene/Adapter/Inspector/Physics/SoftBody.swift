import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func softBodySection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(SoftBody.self, for: entity) else { return nil }
        let state = scene.softBodyStateFrame.states[entity]
        return EditorInspectorSection(
            id: "soft-body",
            title: L("Soft Body"),
            fields: [
                EditorInspectorField(id: "soft-body-enabled", label: L("Enabled"),
                                     value: .bool(softBodyBoolBinding(for: entity, \.isEnabled))),
                EditorInspectorField(id: "soft-body-vertex-mass", label: L("Vertex Mass"),
                                     value: .constrainedNumber(softBodyFloatBinding(for: entity, \.vertexMass, min: 0.0001), min: 0.0001, max: nil, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "soft-body-pressure", label: L("Pressure"),
                                     value: .constrainedNumber(softBodyFloatBinding(for: entity, \.pressure, min: 0), min: 0, max: nil, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "soft-body-damping", label: L("Linear Damping"),
                                     value: .constrainedNumber(softBodyFloatBinding(for: entity, \.linearDamping, min: 0), min: 0, max: nil, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "soft-body-friction", label: L("Friction"),
                                     value: .constrainedNumber(softBodyFloatBinding(for: entity, \.friction, min: 0), min: 0, max: nil, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "soft-body-restitution", label: L("Restitution"),
                                     value: .constrainedNumber(softBodyFloatBinding(for: entity, \.restitution, min: 0, max: 1), min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "soft-body-gravity", label: L("Gravity Scale"),
                                     value: .constrainedNumber(softBodyFloatBinding(for: entity, \.gravityScale), min: nil, max: nil, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "soft-body-vertex-radius", label: L("Vertex Radius"),
                                     value: .constrainedNumber(softBodyFloatBinding(for: entity, \.vertexRadius, min: 0), min: 0, max: nil, step: 0.005, showsStepper: true)),
                EditorInspectorField(id: "soft-body-iterations", label: L("Solver Iterations"),
                                     value: .constrainedNumber(softBodyIterationsBinding(for: entity), min: 1, max: 128, step: 1, showsStepper: true)),
                EditorInspectorField(id: "soft-body-max-velocity", label: L("Max Velocity"),
                                     value: .constrainedNumber(softBodyFloatBinding(for: entity, \.maxLinearVelocity, min: 0), min: 0, max: nil, step: 1, showsStepper: true)),
                EditorInspectorField(id: "soft-body-layer", label: L("Layer"),
                                     value: .constrainedNumber(softBodyLayerBinding(for: entity, \.layerID, max: 15), min: 0, max: 15, step: 1, showsStepper: true)),
                EditorInspectorField(id: "soft-body-layer-mask", label: L("Layer Mask"),
                                     value: .constrainedNumber(softBodyLayerBinding(for: entity, \.layerMask, max: 65_535), min: 0, max: 65_535, step: 1, showsStepper: true)),
                EditorInspectorField(id: "soft-body-allow-sleep", label: L("Allow Sleep"),
                                     value: .bool(softBodyBoolBinding(for: entity, \.allowSleep))),
                EditorInspectorField(id: "soft-body-double-sided", label: L("Double Sided"),
                                     value: .bool(softBodyBoolBinding(for: entity, \.facesDoubleSided))),
                EditorInspectorField(id: "soft-body-self-collision", label: L("Self Collision"),
                                     value: .bool(softBodyBoolBinding(for: entity, \.selfCollision))),
                EditorInspectorField(id: "soft-body-streamed-vertices", label: L("Streamed Vertices"),
                                     value: .readOnly(String(state?.positions.count ?? 0))),
                EditorInspectorField(id: "soft-body-sleeping", label: L("Sleeping"),
                                     value: .readOnly((state?.isSleeping ?? false) ? L("Yes") : L("No"))),
            ]
        )
    }

    func clothSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let cloth = scene.component(Cloth.self, for: entity) else { return nil }
        return EditorInspectorSection(
            id: "cloth",
            title: L("Cloth"),
            fields: [
                EditorInspectorField(id: "cloth-grid-x", label: L("Grid X"),
                                     value: .constrainedNumber(clothGridBinding(for: entity, axis: .x), min: 2, max: 512, step: 1, showsStepper: true)),
                EditorInspectorField(id: "cloth-grid-z", label: L("Grid Z"),
                                     value: .constrainedNumber(clothGridBinding(for: entity, axis: .z), min: 2, max: 512, step: 1, showsStepper: true)),
                EditorInspectorField(id: "cloth-spacing", label: L("Spacing"),
                                     value: .constrainedNumber(clothFloatBinding(for: entity, \.spacing, min: 0.001), min: 0.001, max: nil, step: 0.01, showsStepper: true)),
                EditorInspectorField(id: "cloth-fixed-vertices", label: L("Fixed Vertex Indices"),
                                     value: .json(clothFixedVerticesBinding(for: entity), minHeight: 58)),
                EditorInspectorField(id: "cloth-compliance", label: L("Stretch Compliance"),
                                     value: .constrainedNumber(clothFloatBinding(for: entity, \.compliance, min: 0), min: 0, max: nil, step: 0.00001, showsStepper: true)),
                EditorInspectorField(id: "cloth-shear-compliance", label: L("Shear Compliance"),
                                     value: .constrainedNumber(clothFloatBinding(for: entity, \.shearCompliance, min: 0), min: 0, max: nil, step: 0.00001, showsStepper: true)),
                EditorInspectorField(id: "cloth-bend-compliance", label: L("Bend Compliance"),
                                     value: .constrainedNumber(clothFloatBinding(for: entity, \.bendCompliance, min: 0), min: 0, max: nil, step: 0.00001, showsStepper: true)),
                EditorInspectorField(id: "cloth-bend-type", label: L("Bend Type"),
                                     value: .text(clothBendTypeBinding(for: entity))),
                EditorInspectorField(id: "cloth-vertex-count", label: L("Vertices"),
                                     value: .readOnly(String(cloth.vertexCount))),
            ]
        )
    }

    func softBodyMeshSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let mesh = scene.component(SoftBodyMesh.self, for: entity) else { return nil }
        let geometry = scene.resource(MeshColliderGeometryResource.self)?
            .geometry(for: mesh.resourceID)
        return EditorInspectorSection(
            id: "soft-body-mesh",
            title: L("Soft Body Mesh"),
            fields: [
                EditorInspectorField(id: "soft-body-mesh-resource", label: L("Geometry Resource"),
                                     value: .text(softBodyMeshResourceBinding(for: entity))),
                EditorInspectorField(id: "soft-body-mesh-fixed", label: L("Fixed Vertex Indices"),
                                     value: .json(softBodyMeshFixedVerticesBinding(for: entity), minHeight: 58)),
                EditorInspectorField(id: "soft-body-mesh-compliance", label: L("Stretch Compliance"),
                                     value: .constrainedNumber(softBodyMeshFloatBinding(for: entity, \.compliance), min: 0, max: nil, step: 0.00001, showsStepper: true)),
                EditorInspectorField(id: "soft-body-mesh-shear", label: L("Shear Compliance"),
                                     value: .constrainedNumber(softBodyMeshFloatBinding(for: entity, \.shearCompliance), min: 0, max: nil, step: 0.00001, showsStepper: true)),
                EditorInspectorField(id: "soft-body-mesh-bend", label: L("Bend Compliance"),
                                     value: .constrainedNumber(softBodyMeshFloatBinding(for: entity, \.bendCompliance), min: 0, max: nil, step: 0.00001, showsStepper: true)),
                EditorInspectorField(id: "soft-body-mesh-volume", label: L("Volume Compliance"),
                                     value: .constrainedNumber(softBodyMeshFloatBinding(for: entity, \.volumeCompliance), min: 0, max: nil, step: 0.00001, showsStepper: true)),
                EditorInspectorField(id: "soft-body-mesh-bend-type", label: L("Bend Type"),
                                     value: .text(softBodyMeshBendTypeBinding(for: entity))),
                EditorInspectorField(id: "soft-body-mesh-vertices", label: L("Vertices"),
                                     value: .readOnly(String(geometry?.positions.count ?? 0))),
                EditorInspectorField(id: "soft-body-mesh-triangles", label: L("Triangles"),
                                     value: .readOnly(String(geometry?.triangleCount ?? 0))),
                EditorInspectorField(id: "soft-body-mesh-tetrahedra", label: L("Tetrahedra"),
                                     value: .readOnly(String(geometry?.tetrahedronCount ?? 0))),
                EditorInspectorField(id: "soft-body-mesh-revision", label: L("Geometry Revision"),
                                     value: .readOnly(geometry.map { String($0.revision) } ?? L("Missing"))),
            ]
        )
    }

    private func softBodyFloatBinding(
        for entity: EntityID,
        _ keyPath: WritableKeyPath<SoftBody, Float>,
        min minimum: Float? = nil,
        max maximum: Float? = nil
    ) -> Binding<Float> {
        Binding(
            get: { [self] in scene.component(SoftBody.self, for: entity)?[keyPath: keyPath] ?? 0 },
            set: { [self] next in
                var value = next
                if let minimum { value = Swift.max(minimum, value) }
                if let maximum { value = Swift.min(maximum, value) }
                guard updateComponentData(SoftBody.self, for: entity, {
                    $0[keyPath: keyPath] = value
                }) else { return }
            }
        )
    }

    private func softBodyBoolBinding(
        for entity: EntityID,
        _ keyPath: WritableKeyPath<SoftBody, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { [self] in scene.component(SoftBody.self, for: entity)?[keyPath: keyPath] ?? false },
            set: { [self] value in
                guard updateComponentData(SoftBody.self, for: entity, {
                    $0[keyPath: keyPath] = value
                }) else { return }
            }
        )
    }

    private func softBodyIterationsBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                Float(scene.component(SoftBody.self, for: entity)?.solverIterations ?? 1)
            },
            set: { [self] value in
                let iterations = max(1, min(Int(value.rounded()), 128))
                guard updateComponentData(SoftBody.self, for: entity, {
                    $0.solverIterations = iterations
                }) else { return }
            }
        )
    }

    private func softBodyLayerBinding(
        for entity: EntityID,
        _ keyPath: WritableKeyPath<SoftBody, UInt16>,
        max maximum: UInt16
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                Float(scene.component(SoftBody.self, for: entity)?[keyPath: keyPath] ?? 0)
            },
            set: { [self] value in
                let rounded = max(0, min(Int(value.rounded()), Int(maximum)))
                guard updateComponentData(SoftBody.self, for: entity, {
                    $0[keyPath: keyPath] = UInt16(rounded)
                }) else { return }
            }
        )
    }

    private enum ClothGridAxis: Equatable { case x, z }

    private func clothGridBinding(
        for entity: EntityID,
        axis: ClothGridAxis
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                guard let cloth = scene.component(Cloth.self, for: entity) else { return 2 }
                return Float(axis == .x ? cloth.gridSizeX : cloth.gridSizeZ)
            },
            set: { [self] value in
                guard let cloth = scene.component(Cloth.self, for: entity) else { return }
                let size = max(2, min(Int(value.rounded()), 512))
                let next = Cloth(
                    gridSizeX: axis == .x ? size : cloth.gridSizeX,
                    gridSizeZ: axis == .z ? size : cloth.gridSizeZ,
                    spacing: cloth.spacing,
                    fixedVertexIndices: cloth.fixedVertexIndices,
                    compliance: cloth.compliance,
                    shearCompliance: cloth.shearCompliance,
                    bendCompliance: cloth.bendCompliance,
                    bendType: cloth.bendType
                )
                guard setComponentData(next, for: entity) else { return }
            }
        )
    }

    private func clothFloatBinding(
        for entity: EntityID,
        _ keyPath: WritableKeyPath<Cloth, Float>,
        min minimum: Float? = nil
    ) -> Binding<Float> {
        Binding(
            get: { [self] in scene.component(Cloth.self, for: entity)?[keyPath: keyPath] ?? 0 },
            set: { [self] next in
                let value = minimum.map { Swift.max($0, next) } ?? next
                guard updateComponentData(Cloth.self, for: entity, {
                    $0[keyPath: keyPath] = value
                }) else { return }
            }
        )
    }

    private func clothFixedVerticesBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                guard let indices = scene.component(Cloth.self, for: entity)?.fixedVertexIndices,
                      let data = try? JSONEncoder().encode(indices)
                else { return "[]" }
                return String(decoding: data, as: UTF8.self)
            },
            set: { [self] text in
                guard let data = text.data(using: .utf8),
                      let indices = try? JSONDecoder().decode([Int].self, from: data),
                      let cloth = scene.component(Cloth.self, for: entity)
                else { return }
                let next = Cloth(
                    gridSizeX: cloth.gridSizeX,
                    gridSizeZ: cloth.gridSizeZ,
                    spacing: cloth.spacing,
                    fixedVertexIndices: indices,
                    compliance: cloth.compliance,
                    shearCompliance: cloth.shearCompliance,
                    bendCompliance: cloth.bendCompliance,
                    bendType: cloth.bendType
                )
                guard setComponentData(next, for: entity) else { return }
            }
        )
    }

    private func clothBendTypeBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                String(describing: scene.component(Cloth.self, for: entity)?.bendType ?? .distance)
            },
            set: { [self] text in
                guard let bendType = ClothBendType.allCases.first(where: {
                    String(describing: $0).caseInsensitiveCompare(text) == .orderedSame
                }), updateComponentData(Cloth.self, for: entity, {
                    $0.bendType = bendType
                }) else { return }
            }
        )
    }

    private func softBodyMeshResourceBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                scene.component(SoftBodyMesh.self, for: entity)?.resourceID ?? ""
            },
            set: { [self] resourceID in
                guard let mesh = scene.component(SoftBodyMesh.self, for: entity) else { return }
                let next = SoftBodyMesh(
                    resourceID: resourceID,
                    fixedVertexIndices: mesh.fixedVertexIndices,
                    compliance: mesh.compliance,
                    shearCompliance: mesh.shearCompliance,
                    bendCompliance: mesh.bendCompliance,
                    volumeCompliance: mesh.volumeCompliance,
                    bendType: mesh.bendType
                )
                guard setComponentData(next, for: entity) else { return }
            }
        )
    }

    private func softBodyMeshFloatBinding(
        for entity: EntityID,
        _ keyPath: WritableKeyPath<SoftBodyMesh, Float>
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(SoftBodyMesh.self, for: entity)?[keyPath: keyPath] ?? 0
            },
            set: { [self] value in
                guard updateComponentData(SoftBodyMesh.self, for: entity, {
                    $0[keyPath: keyPath] = max(0, value)
                }) else { return }
            }
        )
    }

    private func softBodyMeshFixedVerticesBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                guard let indices = scene.component(SoftBodyMesh.self, for: entity)?.fixedVertexIndices,
                      let data = try? JSONEncoder().encode(indices)
                else { return "[]" }
                return String(decoding: data, as: UTF8.self)
            },
            set: { [self] text in
                guard let data = text.data(using: .utf8),
                      let indices = try? JSONDecoder().decode([Int].self, from: data),
                      let mesh = scene.component(SoftBodyMesh.self, for: entity)
                else { return }
                let next = SoftBodyMesh(
                    resourceID: mesh.resourceID,
                    fixedVertexIndices: indices,
                    compliance: mesh.compliance,
                    shearCompliance: mesh.shearCompliance,
                    bendCompliance: mesh.bendCompliance,
                    volumeCompliance: mesh.volumeCompliance,
                    bendType: mesh.bendType
                )
                guard setComponentData(next, for: entity) else { return }
            }
        )
    }

    private func softBodyMeshBendTypeBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                String(describing: scene.component(SoftBodyMesh.self, for: entity)?.bendType ?? .dihedral)
            },
            set: { [self] text in
                guard let bendType = ClothBendType.allCases.first(where: {
                    String(describing: $0).caseInsensitiveCompare(text) == .orderedSame
                }), updateComponentData(SoftBodyMesh.self, for: entity, {
                    $0.bendType = bendType
                }) else { return }
            }
        )
    }
}
