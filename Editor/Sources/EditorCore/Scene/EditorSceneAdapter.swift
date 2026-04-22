import Foundation
import GuavaUIRuntime
import SceneRuntime
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
}

/// 主线程约定的编辑器场景适配层。底层数据来自 Swift `SceneRuntime`，
/// 面板只读取这里导出的树与属性 schema，不再依赖 stub 列表。
public final class EditorSceneAdapter: @unchecked Sendable {
    private var scene = SceneRuntime()
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
        scene.entities()
            .filter { scene.parent(of: $0) == nil }
            .map(buildNode)
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
            title: "General",
            fields: [
                EditorInspectorField(
                    id: "name",
                    label: "Name",
                    value: .text(nameBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "kind",
                    label: "Kind",
                    value: .readOnly(displayKind(for: entity))
                ),
                EditorInspectorField(
                    id: "entity-id",
                    label: "Entity ID",
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
            parentLabel = "Root"
        }

        return EditorInspectorSection(
            id: "hierarchy",
            title: "Hierarchy",
            fields: [
                EditorInspectorField(
                    id: "parent",
                    label: "Parent",
                    value: .readOnly(parentLabel)
                ),
                EditorInspectorField(
                    id: "children",
                    label: "Children",
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
        if let local {
            fields.append(
                EditorInspectorField(
                    id: "local-position",
                    label: "Local Position",
                    value: .readOnly(format(local.translation))
                )
            )
        }
        if let world {
            fields.append(
                EditorInspectorField(
                    id: "world-position",
                    label: "World Position",
                    value: .readOnly(format(world.translation))
                )
            )
        }

        return EditorInspectorSection(id: "transform", title: "Transform", fields: fields)
    }

    private func rigidBodySection(for entity: EntityID) -> EditorInspectorSection? {
        guard let body = scene.component(RigidBody.self, for: entity) else {
            return nil
        }

        return EditorInspectorSection(
            id: "rigid-body",
            title: "Rigid Body",
            fields: [
                EditorInspectorField(
                    id: "motion",
                    label: "Motion",
                    value: .readOnly(body.motionType.rawValue)
                ),
                EditorInspectorField(
                    id: "mass",
                    label: "Mass",
                    value: .readOnly(format(body.mass))
                ),
                EditorInspectorField(
                    id: "gravity-scale",
                    label: "Gravity",
                    value: .readOnly(format(body.gravityScale))
                ),
                EditorInspectorField(
                    id: "allow-sleep",
                    label: "Allow Sleep",
                    value: .bool(rigidBodyAllowSleepBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "sleeping",
                    label: "Sleeping",
                    value: .readOnly(body.isSleeping ? "Yes" : "No")
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
            title: "Collider",
            fields: [
                EditorInspectorField(
                    id: "shape",
                    label: "Shape",
                    value: .readOnly(describe(collider.shape))
                ),
                EditorInspectorField(
                    id: "trigger",
                    label: "Trigger",
                    value: .bool(colliderTriggerBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "layer",
                    label: "Layer",
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
            title: "Constraint",
            fields: [
                EditorInspectorField(
                    id: "type",
                    label: "Type",
                    value: .readOnly(constraint.constraintType.rawValue)
                ),
                EditorInspectorField(
                    id: "entity-a",
                    label: "Entity A",
                    value: .readOnly(displayName(for: constraint.entityA))
                ),
                EditorInspectorField(
                    id: "entity-b",
                    label: "Entity B",
                    value: .readOnly(displayName(for: constraint.entityB))
                ),
                EditorInspectorField(
                    id: "limits",
                    label: "Limits",
                    value: .readOnly("\(format(constraint.minLimit)) ... \(format(constraint.maxLimit))")
                ),
                EditorInspectorField(
                    id: "enabled",
                    label: "Enabled",
                    value: .bool(constraintEnabledBinding(for: entity))
                ),
            ]
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
                if scene.hasComponent(SceneNameComponent.self, for: entity) {
                    _ = scene.updateComponent(SceneNameComponent.self, for: entity) { $0.value = value }
                } else {
                    _ = scene.setComponent(SceneNameComponent(value: value), for: entity)
                }
                publishRevision()
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
                _ = scene.updateComponent(RigidBody.self, for: entity) { $0.allowSleep = next }
                publishRevision()
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
                _ = scene.updateComponent(Collider.self, for: entity) { $0.isTrigger = next }
                publishRevision()
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
                _ = scene.updateComponent(Constraint.self, for: entity) { $0.isEnabled = next }
                publishRevision()
            }
        )
    }

    private func publishRevision() {
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
}

private extension EntityID {
    init?(rawValue: UInt64) {
        self.init(
            index: UInt32(rawValue & 0xFFFF_FFFF),
            generation: UInt32(rawValue >> 32)
        )
    }
}