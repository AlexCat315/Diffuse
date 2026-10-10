import GuavaUIRuntime
import SceneRuntime

public struct EditorInspectorSection {
    public let id: String
    public let title: String
    public var fields: [EditorInspectorField]
    public var groups: [EditorInspectorFieldGroup]
    public var componentTypeID: String? = nil

    public init(id: String, title: String, fields: [EditorInspectorField], groups: [EditorInspectorFieldGroup] = []) {
        self.id = id
        self.title = title
        self.fields = fields
        self.groups = groups
    }
}

/// Presentation of one behavior instance. Fields remain the canonical bindings;
/// the group identifies which belong in its header, menu and property form.
public struct EditorInspectorFieldGroup {
    public let id: String
    public let title: String
    public let fieldIDs: [String]
    public let enabledFieldID: String
    public let statusFieldID: String
    public let selectorFieldID: String
    public let actionFieldIDs: [String]
    public let sourceIdentifier: String?

    public init(id: String, title: String, fieldIDs: [String], enabledFieldID: String,
                statusFieldID: String, selectorFieldID: String, actionFieldIDs: [String],
                sourceIdentifier: String? = nil) {
        self.id = id
        self.title = title
        self.fieldIDs = fieldIDs
        self.enabledFieldID = enabledFieldID
        self.statusFieldID = statusFieldID
        self.selectorFieldID = selectorFieldID
        self.actionFieldIDs = actionFieldIDs
        self.sourceIdentifier = sourceIdentifier
    }
}

public enum EditorInspectorFieldPresentation: Sendable {
    case standard
    /// Expert/raw-data access is available, but not part of the default form.
    case advanced
}

public struct EditorInspectorField {
    public let id: String
    public let label: String
    public let value: EditorInspectorFieldValue
    public let presentation: EditorInspectorFieldPresentation
    public let group: String?
    public let isMixed: Bool
    public let mixedAxes: Set<String>
    public let applyPrimaryValue: (() -> Void)?

    public init(id: String, label: String, value: EditorInspectorFieldValue,
                presentation: EditorInspectorFieldPresentation = .standard,
                isMixed: Bool = false, mixedAxes: Set<String> = [],
                applyPrimaryValue: (() -> Void)? = nil, group: String? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.presentation = presentation
        self.group = group
        self.isMixed = isMixed
        self.mixedAxes = mixedAxes
        self.applyPrimaryValue = applyPrimaryValue
    }
}

public struct EditorInspectorEntityOption: Sendable, Equatable {
    public let id: UInt64
    public let name: String

    public init(id: UInt64, name: String) {
        self.id = id
        self.name = name
    }
}

public struct EditorInspectorStringOption: Sendable, Equatable {
    public let value: String
    public let label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

public enum EditorInspectorFieldValue {
    case readOnly(String)
    case text(Binding<String>)
    case stringOptions(Binding<String>, options: [EditorInspectorStringOption])
    case action(title: String, isDestructive: Bool, action: () -> Void)
    case bool(Binding<Bool>)
    case number(Binding<Float>)
    case constrainedNumber(Binding<Float>, min: Float?, max: Float?, step: Float?, showsStepper: Bool)
    case vector3(x: Binding<Float>, y: Binding<Float>, z: Binding<Float>)
    case color(Binding<Color>)
    case json(Binding<String>, minHeight: Float)
    case physicsSimulationMode(Binding<PhysicsSimulationMode>)
    case vehicleControllerKind(Binding<VehicleControllerKind>)
    case colliderShapeKind(Binding<ColliderShapeKind>)
    case colliderShapeInstances(Binding<[ColliderShapeInstance]>)
    case entityReference(Binding<UInt64>, options: [EditorInspectorEntityOption])
    case physicsJointKind(Binding<PhysicsJointKind>)
    case physicsJointMotorMode(Binding<PhysicsJointMotorMode>)
    case particleEmissionShape(Binding<ParticleEmissionShape>)
    case particleCollisionMode(Binding<ParticleCollisionMode>)
    case particleSimulationSpace(Binding<ParticleSimulationSpace>)
    case particleSimulationBackend(Binding<ParticleSimulationBackend>)
    case particleCurve(Binding<ParticleCurve>)
    case particleBlendMode(Binding<ParticleBlendMode>)
    case particleRenderMode(Binding<ParticleRenderMode>)
    case particleSortMode(Binding<ParticleSortMode>)
    case particleTextureSheetPlaybackMode(Binding<ParticleTextureSheetPlaybackMode>)
    case particleRenderAlignment(Binding<ParticleRenderAlignment>)
    case particleRenderBoundsMode(Binding<ParticleRenderBoundsMode>)
    case particleForceMode(Binding<ParticleForceMode>)
    case particleVectorFieldMode(Binding<ParticleVectorFieldMode>)
    case particleSubEmitterTrigger(Binding<ParticleSubEmitterTrigger>)
    case particleSubEmitters(Binding<[ParticleSubEmitter]>)
    case particleModuleStack(Binding<ParticleModuleStack>)
    case asset(Binding<EditorInspectorAssetRef?>, acceptedKinds: Set<String>, placeholder: String)
}

public struct EditorInspectorAssetRef: Sendable, Equatable {
    public let id: String
    public let name: String
    public let subtitle: String?
    public let kind: String
    public let previewPath: String?

    public init(id: String,
                name: String,
                subtitle: String? = nil,
                kind: String,
                previewPath: String? = nil) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.kind = kind
        self.previewPath = previewPath
    }
}
