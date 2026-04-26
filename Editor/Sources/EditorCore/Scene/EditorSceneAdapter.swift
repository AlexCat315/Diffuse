import Foundation
import GuavaUIRuntime
import IntentRuntime
import SceneRuntime
import ScriptRuntime
import simd

public struct EditorSceneNode: Identifiable {
    public let id: UInt64
    public let name: String
    public let kind: String
    public let children: [EditorSceneNode]

    public init(id: UInt64,
                name: String,
                kind: String,
                children: [EditorSceneNode]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.children = children
    }
}

public struct EditorSceneEntitySummary {
    public let id: UInt64
    public let name: String
    public let kind: String

    public init(id: UInt64, name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public struct EditorInspectorSection {
    public let id: String
    public let title: String
    public let fields: [EditorInspectorField]

    public init(id: String, title: String, fields: [EditorInspectorField]) {
        self.id = id
        self.title = title
        self.fields = fields
    }
}

public struct EditorInspectorField {
    public let id: String
    public let label: String
    public let value: EditorInspectorFieldValue

    public init(id: String, label: String, value: EditorInspectorFieldValue) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public enum EditorInspectorFieldValue {
    case readOnly(String)
    case text(Binding<String>)
    case bool(Binding<Bool>)
    case number(Binding<Float>)
    case constrainedNumber(Binding<Float>, min: Float?, max: Float?, step: Float?, showsStepper: Bool)
    case vector3(x: Binding<Float>, y: Binding<Float>, z: Binding<Float>)
    case color(Binding<Color>)
    case json(Binding<String>, minHeight: Float)
    case lightType(Binding<LightType>)
    case rigidBodyMotion(Binding<RigidBodyMotionType>)
}

/// 主线程约定的编辑器场景适配层。底层数据来自 Swift `SceneRuntime`，
/// 面板只读取这里导出的树与属性 schema，不再依赖 stub 列表。
public final class EditorSceneAdapter: @unchecked Sendable {
    var scene = SceneRuntime()
    let transactionExecutor = TransactionExecutor()
    private var initialSelectionID: UInt64?
    private var initialExpandedIDs: Set<UInt64> = []

    public var onRevisionChanged: ((UInt64) -> Void)?

    public init() {
        scene.bootstrapEditorPreviewScene()
        let defaults = scene.resource(SceneBootstrapDefaultsResource.self)
        initialSelectionID = defaults?.defaultSelection?.rawValue
        initialExpandedIDs = Set(defaults?.defaultExpanded.map(\ .rawValue) ?? [])
    }

    public var revision: UInt64 {
        scene.snapshot.revision
    }

    public var entityCount: Int {
        scene.snapshot.entityCount
    }

    public var defaultSelectionID: UInt64? {
        initialSelectionID
    }

    public var defaultExpandedEntityIDs: Set<UInt64> {
        initialExpandedIDs
    }

    public var roots: [EditorSceneNode] {
        scene.roots().map(buildNode)
    }

    @discardableResult
    public func moveEntity(_ entityID: UInt64,
                           to parentID: UInt64?,
                           at index: Int) -> TransactionApplyResult? {
        applySceneTransaction(intentVerb: "scene.move_entity",
                              summary: "Move entity in hierarchy",
                              targetRawIDs: [entityID],
                              mutations: [.moveEntity(entityID: entityID,
                                                      parentID: parentID,
                                                      index: index)])
    }

    public func entitySummary(id rawID: UInt64?) -> EditorSceneEntitySummary? {
        guard let entity = entity(from: rawID), scene.contains(entity) else {
            return nil
        }
        return EditorSceneEntitySummary(
            id: entity.rawValue,
            name: displayName(for: entity),
            kind: displayKind(for: entity)
        )
    }

    public func inspectorSections(for rawID: UInt64?) -> [EditorInspectorSection] {
        guard let entity = entity(from: rawID), scene.contains(entity) else {
            return []
        }

        var sections: [EditorInspectorSection] = [
            generalSection(for: entity),
            hierarchySection(for: entity),
        ]

        if let transformSection = transformSection(for: entity) {
            sections.append(transformSection)
        }
        if let rigidBodySection = rigidBodySection(for: entity) {
            sections.append(rigidBodySection)
        }
        if let colliderSection = colliderSection(for: entity) {
            sections.append(colliderSection)
        }
        if let constraintSection = constraintSection(for: entity) {
            sections.append(constraintSection)
        }
        if let lightSection = lightSection(for: entity) {
            sections.append(lightSection)
        }
        if let scriptSection = scriptSection(for: entity) {
            sections.append(scriptSection)
        }

        return sections
    }

    private func buildNode(_ entity: EntityID) -> EditorSceneNode {
        EditorSceneNode(
            id: entity.rawValue,
            name: displayName(for: entity),
            kind: displayKind(for: entity),
            children: scene.children(of: entity).map(buildNode)
        )
    }

    private func generalSection(for entity: EntityID) -> EditorInspectorSection {
        EditorInspectorSection(
            id: "general",
            title: L("General"),
            fields: [
                EditorInspectorField(
                    id: "name",
                    label: L("Name"),
                    value: .text(nameBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "kind",
                    label: L("Kind"),
                    value: .readOnly(displayKind(for: entity))
                ),
                EditorInspectorField(
                    id: "entity-id",
                    label: L("Entity ID"),
                    value: .readOnly(String(entity.rawValue))
                ),
            ]
        )
    }

    private func hierarchySection(for entity: EntityID) -> EditorInspectorSection {
        let parentLabel: String
        if let parent = scene.parent(of: entity) {
            parentLabel = displayName(for: parent)
        } else {
            parentLabel = L("Root")
        }

        return EditorInspectorSection(
            id: "hierarchy",
            title: L("Hierarchy"),
            fields: [
                EditorInspectorField(
                    id: "parent",
                    label: L("Parent"),
                    value: .readOnly(parentLabel)
                ),
                EditorInspectorField(
                    id: "children",
                    label: L("Children"),
                    value: .readOnly(String(scene.children(of: entity).count))
                ),
            ]
        )
    }

    private func transformSection(for entity: EntityID) -> EditorInspectorSection? {
        let local = scene.localTransform(for: entity)
        let world = scene.worldTransform(for: entity)
        guard local != nil || world != nil else { return nil }

        var fields: [EditorInspectorField] = []
        if local != nil {
            fields.append(
                EditorInspectorField(
                    id: "local-position",
                    label: L("Local Position"),
                    value: .vector3(x: localPositionBinding(for: entity, axis: \.x),
                                    y: localPositionBinding(for: entity, axis: \.y),
                                    z: localPositionBinding(for: entity, axis: \.z))
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "local-rotation",
                    label: L("Rotation"),
                    value: .vector3(x: localRotationBinding(for: entity, axis: \.x),
                                    y: localRotationBinding(for: entity, axis: \.y),
                                    z: localRotationBinding(for: entity, axis: \.z))
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "local-scale",
                    label: L("Scale"),
                    value: .vector3(x: localScaleBinding(for: entity, axis: \.x),
                                    y: localScaleBinding(for: entity, axis: \.y),
                                    z: localScaleBinding(for: entity, axis: \.z))
                )
            )
        }
        if world != nil {
            let displayed = entityWorldPosition(entity.rawValue) ?? world!.translation
            fields.append(
                EditorInspectorField(
                    id: "world-position",
                    label: L("World Position"),
                    value: .readOnly(format(displayed))
                )
            )
        }

        return EditorInspectorSection(id: "transform", title: L("Transform"), fields: fields)
    }

    private func rigidBodySection(for entity: EntityID) -> EditorInspectorSection? {
        guard let body = scene.component(RigidBody.self, for: entity) else {
            return nil
        }

        return EditorInspectorSection(
            id: "rigid-body",
            title: L("Rigid Body"),
            fields: [
                EditorInspectorField(
                    id: "motion",
                    label: L("Motion"),
                    value: .rigidBodyMotion(rigidBodyMotionBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "mass",
                    label: L("Mass"),
                    value: .constrainedNumber(rigidBodyMassBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.5,
                                              showsStepper: true)
                ),
                EditorInspectorField(
                    id: "gravity-scale",
                    label: L("Gravity"),
                    value: .constrainedNumber(rigidBodyGravityScaleBinding(for: entity),
                                              min: nil,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                ),
                EditorInspectorField(
                    id: "allow-sleep",
                    label: L("Allow Sleep"),
                    value: .bool(rigidBodyAllowSleepBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "sleeping",
                    label: L("Sleeping"),
                    value: .readOnly(body.isSleeping ? L("Yes") : L("No"))
                ),
            ]
        )
    }

    private func colliderSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let collider = scene.component(Collider.self, for: entity) else {
            return nil
        }

        return EditorInspectorSection(
            id: "collider",
            title: L("Collider"),
            fields: [
                EditorInspectorField(
                    id: "shape",
                    label: L("Shape"),
                    value: .readOnly(describe(collider.shape))
                ),
                EditorInspectorField(
                    id: "trigger",
                    label: L("Trigger"),
                    value: .bool(colliderTriggerBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "layer",
                    label: L("Layer"),
                    value: .readOnly(String(collider.layerID))
                ),
            ]
        )
    }

    private func constraintSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let constraint = scene.component(Constraint.self, for: entity) else {
            return nil
        }

        return EditorInspectorSection(
            id: "constraint",
            title: L("Constraint"),
            fields: [
                EditorInspectorField(
                    id: "type",
                    label: L("Type"),
                    value: .readOnly(constraint.constraintType.rawValue)
                ),
                EditorInspectorField(
                    id: "entity-a",
                    label: L("Entity A"),
                    value: .readOnly(displayName(for: constraint.entityA))
                ),
                EditorInspectorField(
                    id: "entity-b",
                    label: L("Entity B"),
                    value: .readOnly(displayName(for: constraint.entityB))
                ),
                EditorInspectorField(
                    id: "limits",
                    label: L("Limits"),
                    value: .readOnly("\(format(constraint.minLimit)) ... \(format(constraint.maxLimit))")
                ),
                EditorInspectorField(
                    id: "enabled",
                    label: L("Enabled"),
                    value: .bool(constraintEnabledBinding(for: entity))
                ),
            ]
        )
    }

    private func lightSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let light = scene.component(LightComponent.self, for: entity) else {
            return nil
        }

        var fields: [EditorInspectorField] = [
            EditorInspectorField(
                id: "type",
                label: L("Type"),
                value: .lightType(lightTypeBinding(for: entity))
            ),
            EditorInspectorField(
                id: "color",
                label: L("Color"),
                value: .color(lightColorBinding(for: entity))
            )
        ]

        switch light.type {
        case .directional:
            fields.append(
                EditorInspectorField(
                    id: "intensity",
                    label: L("Intensity"),
                    value: .number(lightIntensityBinding(for: entity))
                )
            )
        case .point:
            fields.append(
                EditorInspectorField(
                    id: "intensity",
                    label: L("Intensity"),
                    value: .constrainedNumber(lightIntensityBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "range",
                    label: L("Range"),
                    value: .constrainedNumber(lightRangeBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                )
            )
        case .spot:
            fields.append(
                EditorInspectorField(
                    id: "intensity",
                    label: L("Intensity"),
                    value: .constrainedNumber(lightIntensityBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "range",
                    label: L("Range"),
                    value: .constrainedNumber(lightRangeBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "spot-inner-angle",
                    label: L("Inner Angle"),
                    value: .constrainedNumber(lightSpotInnerAngleBinding(for: entity),
                                              min: 0,
                                              max: 179,
                                              step: 1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "spot-outer-angle",
                    label: L("Outer Angle"),
                    value: .constrainedNumber(lightSpotOuterAngleBinding(for: entity),
                                              min: 1,
                                              max: 179,
                                              step: 1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "spot-cone-hint",
                    label: L("Cone"),
                    value: .readOnly("\(format(light.spotInnerAngleDegrees))° -> \(format(light.spotOuterAngleDegrees))°")
                )
            )
        }

        return EditorInspectorSection(
            id: "light",
            title: L("Light"),
            fields: fields
        )
    }

    private func scriptSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let component = scene.component(ScriptComponent.self, for: entity) else {
            return nil
        }

        var fields: [EditorInspectorField] = []
        for (index, binding) in component.bindings.enumerated() {
            let ordinal = index + 1
            fields.append(
                EditorInspectorField(
                    id: "script-\(index)-enabled",
                    label: String(format: L("Script %d"), ordinal),
                    value: .bool(scriptEnabledBinding(for: entity, index: index))
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "script-\(index)-handle",
                    label: L("Handle"),
                    value: .readOnly("#\(binding.script.rawValue)")
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "script-\(index)-parameters",
                    label: L("Parameters"),
                    value: .json(scriptParametersBinding(for: entity, index: index), minHeight: 96)
                )
            )
        }

        if fields.isEmpty {
            fields.append(
                EditorInspectorField(
                    id: "script-empty",
                    label: L("Bindings"),
                    value: .readOnly(L("No scripts"))
                )
            )
        }

        return EditorInspectorSection(id: "scripts", title: L("Scripts"), fields: fields)
    }

    private func lightTypeBinding(for entity: EntityID) -> Binding<LightType> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.type ?? .directional
            },
            set: { [self] next in
                guard scene.component(LightComponent.self, for: entity)?.type != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_type",
                                          summary: "Update light type",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightType(entityID: entity.rawValue, type: next)])
            }
        )
    }

    private func nameBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                scene.component(SceneNameComponent.self, for: entity)?.value ?? fallbackName(for: entity)
            },
            set: { [self] next in
                let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = trimmed.isEmpty ? fallbackName(for: entity) : trimmed
                guard scene.component(SceneNameComponent.self, for: entity)?.value != value else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_name",
                                          summary: "Rename entity",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setSceneName(entityID: entity.rawValue, value: value)])
            }
        )
    }

    private func rigidBodyAllowSleepBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.allowSleep ?? false
            },
            set: { [self] next in
                guard scene.component(RigidBody.self, for: entity)?.allowSleep != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_allow_sleep",
                                          summary: "Update rigid body sleep flag",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRigidBodyAllowSleep(entityID: entity.rawValue, value: next)])
            }
        )
    }

    private func rigidBodyMotionBinding(for entity: EntityID) -> Binding<RigidBodyMotionType> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.motionType ?? .dynamic
            },
            set: { [self] next in
                guard scene.component(RigidBody.self, for: entity)?.motionType != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_motion",
                                          summary: "Update rigid body motion type",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRigidBodyMotionType(entityID: entity.rawValue, value: next)])
            }
        )
    }

    private func rigidBodyMassBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.mass ?? 0
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(RigidBody.self, for: entity)?.mass != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_mass",
                                          summary: "Update rigid body mass",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRigidBodyMass(entityID: entity.rawValue, value: clamped)])
            }
        )
    }

    private func rigidBodyGravityScaleBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.gravityScale ?? 0
            },
            set: { [self] next in
                guard scene.component(RigidBody.self, for: entity)?.gravityScale != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_gravity_scale",
                                          summary: "Update rigid body gravity scale",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRigidBodyGravityScale(entityID: entity.rawValue, value: next)])
            }
        )
    }

    private func colliderTriggerBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.isTrigger ?? false
            },
            set: { [self] next in
                guard scene.component(Collider.self, for: entity)?.isTrigger != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_trigger",
                                          summary: "Update collider trigger flag",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderTrigger(entityID: entity.rawValue, value: next)])
            }
        )
    }

    private func constraintEnabledBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(Constraint.self, for: entity)?.isEnabled ?? false
            },
            set: { [self] next in
                guard scene.component(Constraint.self, for: entity)?.isEnabled != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_constraint_enabled",
                                          summary: "Update constraint enabled flag",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setConstraintEnabled(entityID: entity.rawValue, value: next)])
            }
        )
    }

    private func lightColorBinding(for entity: EntityID) -> Binding<Color> {
        Binding(
            get: { [self] in
                let linear = scene.component(LightComponent.self, for: entity)?.color ?? SIMD3<Float>(1, 1, 1)
                return Color(r: linear.x, g: linear.y, b: linear.z, a: 1)
            },
            set: { [self] next in
                let nextColor = SIMD3<Float>(
                    max(0, min(1, next.r)),
                    max(0, min(1, next.g)),
                    max(0, min(1, next.b))
                )
                guard scene.component(LightComponent.self, for: entity)?.color != nextColor else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_color",
                                          summary: "Update light color",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightColor(entityID: entity.rawValue, color: nextColor)])
            }
        )
    }

    private func lightIntensityBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.intensity ?? 1
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(LightComponent.self, for: entity)?.intensity != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_intensity",
                                          summary: "Update light intensity",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightIntensity(entityID: entity.rawValue, intensity: clamped)])
            }
        )
    }

    private func lightRangeBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.range ?? 10
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(LightComponent.self, for: entity)?.range != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_range",
                                          summary: "Update light range",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightRange(entityID: entity.rawValue, range: clamped)])
            }
        )
    }

    private func lightSpotInnerAngleBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.spotInnerAngleDegrees ?? 20
            },
            set: { [self] next in
                let currentOuter = scene.component(LightComponent.self, for: entity)?.spotOuterAngleDegrees ?? 30
                let clamped = max(0, min(currentOuter, next))
                guard scene.component(LightComponent.self, for: entity)?.spotInnerAngleDegrees != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_spot_inner_angle",
                                          summary: "Update spotlight inner angle",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightSpotInnerAngle(entityID: entity.rawValue, angleDegrees: clamped)])
            }
        )
    }

    private func lightSpotOuterAngleBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.spotOuterAngleDegrees ?? 30
            },
            set: { [self] next in
                let clamped = max(1, min(179, next))
                guard scene.component(LightComponent.self, for: entity)?.spotOuterAngleDegrees != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_spot_outer_angle",
                                          summary: "Update spotlight outer angle",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightSpotOuterAngle(entityID: entity.rawValue, angleDegrees: clamped)])
            }
        )
    }

    private func scriptEnabledBinding(for entity: EntityID, index: Int) -> Binding<Bool> {
        Binding(
            get: { [self] in
                guard let bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index)
                else { return false }
                return bindings[index].isEnabled
            },
            set: { [self] next in
                guard var bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index),
                      bindings[index].isEnabled != next
                else { return }
                bindings[index].isEnabled = next
                _ = applySceneTransaction(intentVerb: "scene.set_script_enabled",
                                          summary: "Update script enabled flag",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setScriptBindings(entityID: entity.rawValue,
                                                                         bindings: bindings)])
            }
        )
    }

    private func scriptParametersBinding(for entity: EntityID, index: Int) -> Binding<String> {
        Binding(
            get: { [self] in
                guard let bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index)
                else { return "{}" }
                return normalizedJSONCommitText(bindings[index].parametersJSON)
            },
            set: { [self] next in
                let normalized = normalizedJSONCommitText(next)
                guard isValidJSONDocument(normalized),
                      var bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index),
                      bindings[index].parametersJSON != normalized
                else { return }
                bindings[index].parametersJSON = normalized
                _ = applySceneTransaction(intentVerb: "scene.set_script_parameters",
                                          summary: "Update script parameters",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setScriptBindings(entityID: entity.rawValue,
                                                                         bindings: bindings)])
            }
        )
    }

    private func publishRevision() {
        onRevisionChanged?(scene.snapshot.revision)
    }

    func notifyRevisionChanged() {
        onRevisionChanged?(scene.snapshot.revision)
    }

    private func displayName(for entity: EntityID) -> String {
        scene.component(SceneNameComponent.self, for: entity)?.value ?? fallbackName(for: entity)
    }

    private func displayKind(for entity: EntityID) -> String {
        if let kind = scene.component(SceneKindComponent.self, for: entity)?.value {
            return kind
        }
        if scene.hasComponent(Constraint.self, for: entity) {
            return "Constraint"
        }
        if scene.hasComponent(RigidBody.self, for: entity) || scene.hasComponent(Collider.self, for: entity) {
            return "Physics Entity"
        }
        if scene.hasComponent(ScriptComponent.self, for: entity) {
            return "Scripted Entity"
        }
        return "Entity"
    }

    private func fallbackName(for entity: EntityID) -> String {
        "Entity \(entity.index)"
    }

    private func describe(_ shape: ColliderShape) -> String {
        switch shape {
        case let .box(halfExtents, _):
            return "Box \(format(halfExtents * 2))"
        case let .sphere(radius, _):
            return "Sphere r=\(format(radius))"
        case let .capsule(radius, halfHeight, _):
            return "Capsule r=\(format(radius)) h=\(format(halfHeight * 2))"
        case let .mesh(resourceID, _):
            return resourceID.map { "Mesh \($0)" } ?? "Mesh"
        }
    }

    private func format(_ value: SIMD3<Float>) -> String {
        "\(format(value.x)), \(format(value.y)), \(format(value.z))"
    }

    private func format(_ value: Float) -> String {
        String(format: "%.2f", value)
    }

    private func entity(from rawID: UInt64?) -> EntityID? {
        guard let rawID else { return nil }
        return EntityID(rawValue: rawID)
    }

    // MARK: - Transform bindings

    private func localPositionBinding(for entity: EntityID,
                                      axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { [self] in
                let t = scene.localTransform(for: entity)?.translation ?? .zero
                return t[keyPath: axis]
            },
            set: { [self] next in
                var local = scene.localTransform(for: entity) ?? LocalTransform()
                var translation = local.translation
                guard translation[keyPath: axis] != next else { return }
                translation[keyPath: axis] = next
                local.matrix.columns.3 = SIMD4<Float>(translation, 1)
                _ = applySceneTransaction(intentVerb: "scene.set_local_transform",
                                          summary: "Update entity translation",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLocalTransform(entityID: entity.rawValue, transform: local)])
            }
        )
    }

    private func localScaleBinding(for entity: EntityID,
                                   axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { [self] in
                let m = scene.localTransform(for: entity)?.matrix ?? matrix_identity_float4x4
                let (_, scale) = decomposeRotationScale(m)
                return scale[keyPath: axis]
            },
            set: { [self] next in
                var local = scene.localTransform(for: entity) ?? LocalTransform()
                let (rot, _) = decomposeRotationScale(local.matrix)
                let translation = SIMD3<Float>(local.matrix.columns.3.x,
                                               local.matrix.columns.3.y,
                                               local.matrix.columns.3.z)
                var scale = decomposeRotationScale(local.matrix).1
                guard scale[keyPath: axis] != next else { return }
                scale[keyPath: axis] = next
                local.matrix = composeMatrix(translation: translation, rotation: rot, scale: scale)
                _ = applySceneTransaction(intentVerb: "scene.set_local_transform",
                                          summary: "Update entity scale",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLocalTransform(entityID: entity.rawValue, transform: local)])
            }
        )
    }

    private func localRotationBinding(for entity: EntityID,
                                      axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { [self] in
                let m = scene.localTransform(for: entity)?.matrix ?? matrix_identity_float4x4
                let (rot, _) = decomposeRotationScale(m)
                let euler = eulerXYZFromMatrix(rot)
                let deg = euler * (180.0 / .pi)
                return deg[keyPath: axis]
            },
            set: { [self] next in
                var local = scene.localTransform(for: entity) ?? LocalTransform()
                let (_, scale) = decomposeRotationScale(local.matrix)
                let translation = SIMD3<Float>(local.matrix.columns.3.x,
                                               local.matrix.columns.3.y,
                                               local.matrix.columns.3.z)
                let currentDegrees = eulerXYZFromMatrix(decomposeRotationScale(local.matrix).0) * (180.0 / .pi)
                guard currentDegrees[keyPath: axis] != next else { return }
                var degrees = currentDegrees
                degrees[keyPath: axis] = next
                let radians = degrees * (.pi / 180.0)
                let rot = matrixFromEulerXYZ(radians)
                local.matrix = composeMatrix(translation: translation, rotation: rot, scale: scale)
                _ = applySceneTransaction(intentVerb: "scene.set_local_transform",
                                          summary: "Update entity rotation",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLocalTransform(entityID: entity.rawValue, transform: local)])
            }
        )
    }

    @discardableResult
    func applySceneTransaction(intentVerb: String,
                               summary: String,
                               targetRawIDs: [UInt64] = [],
                               mutations: [SceneMutation]) -> TransactionApplyResult? {
        let intent = IntentIR(verb: intentVerb,
                              summary: summary,
                              targetObjectIDs: targetRawIDs.map { "scene:\($0)" },
                              source: .human)
        let transaction = TransactionIR(intent: intent,
                                        summary: summary,
                                        operations: mutations.map(TransactionOperation.scene),
                                        baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
                                        provenance: .authored)
        var context = TransactionExecutionContext(sceneRuntime: scene)
        guard let result = try? transactionExecutor.apply(transaction, to: &context),
              let updatedScene = context.sceneRuntime
        else {
            return nil
        }
        scene = updatedScene
        notifyRevisionChanged()
        return result
    }

}

private extension EntityID {
    init?(rawValue: UInt64) {
        self.init(
            index: UInt32(rawValue & 0xFFFF_FFFF),
            generation: UInt32(rawValue >> 32)
        )
    }
}

// MARK: - Transform decompose / compose

/// 把 4x4 本地矩阵分解成纯旋转 3x3 + per-axis 缩放向量。
/// 假设矩阵不含切变；如果有切变，缩放只取列长度近似。
private func decomposeRotationScale(_ m: simd_float4x4) -> (simd_float3x3, SIMD3<Float>) {
    let c0 = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
    let c1 = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
    let c2 = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
    let sx = simd_length(c0)
    let sy = simd_length(c1)
    let sz = simd_length(c2)
    let r0 = sx > 1e-5 ? c0 / sx : SIMD3<Float>(1, 0, 0)
    let r1 = sy > 1e-5 ? c1 / sy : SIMD3<Float>(0, 1, 0)
    let r2 = sz > 1e-5 ? c2 / sz : SIMD3<Float>(0, 0, 1)
    return (simd_float3x3(r0, r1, r2), SIMD3<Float>(sx, sy, sz))
}

private func composeMatrix(translation: SIMD3<Float>,
                           rotation: simd_float3x3,
                           scale: SIMD3<Float>) -> simd_float4x4 {
    let c0 = rotation.columns.0 * scale.x
    let c1 = rotation.columns.1 * scale.y
    let c2 = rotation.columns.2 * scale.z
    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4<Float>(c0, 0)
    m.columns.1 = SIMD4<Float>(c1, 0)
    m.columns.2 = SIMD4<Float>(c2, 0)
    m.columns.3 = SIMD4<Float>(translation, 1)
    return m
}

private func normalizedJSONCommitText(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "{}" : trimmed
}

private func isValidJSONDocument(_ text: String) -> Bool {
    guard let data = text.data(using: .utf8) else { return false }
    do {
        _ = try JSONSerialization.jsonObject(with: data)
        return true
    } catch {
        return false
    }
}

/// 从 3x3 旋转矩阵提取 Euler XYZ（intrinsic 顺序：R = Rx * Ry * Rz）。
/// 这里 simd 是 column-major：m[c][r] 等价数学约定 R[r][c]。
private func eulerXYZFromMatrix(_ m: simd_float3x3) -> SIMD3<Float> {
    // R[r][c] = m.columns[c][r]
    let r02 = m.columns.2.x // R[0][2]
    let r12 = m.columns.2.y // R[1][2]
    let r22 = m.columns.2.z // R[2][2]
    let r00 = m.columns.0.x // R[0][0]
    let r01 = m.columns.1.x // R[0][1]

    let sy = max(-1, min(1, r02))
    let y = asinf(sy)
    let cy = cosf(y)
    let x: Float
    let z: Float
    if abs(cy) > 1e-4 {
        x = atan2f(-r12, r22)
        z = atan2f(-r01, r00)
    } else {
        // gimbal lock: 让 z = 0 解 x。
        x = atan2f(m.columns.0.y, m.columns.1.y) // atan2(R[1][0], R[1][1])
        z = 0
    }
    return SIMD3<Float>(x, y, z)
}

/// 从 Euler XYZ（弧度，intrinsic）合成 3x3 旋转矩阵：R = Rx * Ry * Rz。
private func matrixFromEulerXYZ(_ e: SIMD3<Float>) -> simd_float3x3 {
    let cx = cosf(e.x), sx = sinf(e.x)
    let cy = cosf(e.y), sy = sinf(e.y)
    let cz = cosf(e.z), sz = sinf(e.z)

    // R = Rx * Ry * Rz
    // 逐项展开
    let r00 = cy * cz
    let r01 = -cy * sz
    let r02 = sy
    let r10 = sx * sy * cz + cx * sz
    let r11 = -sx * sy * sz + cx * cz
    let r12 = -sx * cy
    let r20 = -cx * sy * cz + sx * sz
    let r21 = cx * sy * sz + sx * cz
    let r22 = cx * cy

    // simd column-major: columns[c][r] = R[r][c]
    return simd_float3x3(
        SIMD3<Float>(r00, r10, r20),
        SIMD3<Float>(r01, r11, r21),
        SIMD3<Float>(r02, r12, r22)
    )
}
