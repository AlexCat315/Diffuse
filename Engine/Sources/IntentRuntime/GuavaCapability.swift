import CapabilityRuntime
import Foundation
import SceneRuntime
import ScriptRuntime

/// Input types opt into one strict schema. Provider tools, host validation, and
/// decoding all consume this same declaration.
public protocol GuavaCapabilityInput: Codable, Sendable {
    static var inputSchema: JSONSchema { get }
}

/// Column-major local transform copied out of SceneRuntime for pure capability
/// preparation. Keeping this as plain values prevents a capability from
/// retaining or mutating the live scene object.
public struct CapabilityPreparationTransform: Codable, Sendable, Equatable {
    public var columnMajorMatrix: [Float]

    public init?(columnMajorMatrix: [Float]) {
        guard columnMajorMatrix.count == 16,
              columnMajorMatrix.allSatisfy({ $0.isFinite }) else {
            return nil
        }
        self.columnMajorMatrix = columnMajorMatrix
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer().decode([Float].self)
        guard values.count == 16, values.allSatisfy({ $0.isFinite }) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "a capability preparation transform must contain 16 finite values"
            ))
        }
        columnMajorMatrix = values
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(columnMajorMatrix)
    }
}

/// Value-only material state used by read-modify-write capability preparation.
/// Texture handles are deliberately excluded because the AI material primitive
/// cannot author them and must not receive resource-runtime objects.
public struct CapabilityPreparationMaterial: Codable, Sendable, Equatable {
    public var baseColor: [Float]
    public var metallic: Float
    public var roughness: Float
    public var emissive: [Float]

    public init?(baseColor: [Float],
                 metallic: Float,
                 roughness: Float,
                 emissive: [Float]) {
        guard baseColor.count == 4,
              emissive.count == 3,
              baseColor.allSatisfy({ $0.isFinite }),
              emissive.allSatisfy({ $0.isFinite }),
              metallic.isFinite,
              roughness.isFinite else {
            return nil
        }
        self.baseColor = baseColor
        self.metallic = metallic
        self.roughness = roughness
        self.emissive = emissive
    }
}

public struct CapabilityPreparationEntity: Sendable, Equatable {
    public var reference: String
    public var componentTypes: [String]
    public var localTransform: CapabilityPreparationTransform?
    public var renderMaterial: CapabilityPreparationMaterial?
    public var rigidBody: RigidBody?
    public var collider: Collider?
    public var audioSource: AudioSource?
    public var animationPlayer: AnimationPlayer?
    public var scriptBindings: [ScriptBinding]

    public init(reference: String,
                componentTypes: [String] = [],
                localTransform: CapabilityPreparationTransform? = nil,
                renderMaterial: CapabilityPreparationMaterial? = nil,
                rigidBody: RigidBody? = nil,
                collider: Collider? = nil,
                audioSource: AudioSource? = nil,
                animationPlayer: AnimationPlayer? = nil,
                scriptBindings: [ScriptBinding] = []) {
        self.reference = reference
        self.componentTypes = componentTypes.sorted()
        self.localTransform = localTransform
        self.renderMaterial = renderMaterial
        self.rigidBody = rigidBody
        self.collider = collider
        self.audioSource = audioSource
        self.animationPlayer = animationPlayer
        self.scriptBindings = scriptBindings
    }
}

/// A value-only scene view. It intentionally exposes no SceneRuntime,
/// application singleton, file handle, network client, shell, or pointer.
public struct CapabilityPreparationContext: Sendable, Equatable {
    public var sceneRevision: UInt64
    public var entities: [CapabilityPreparationEntity]

    public init(sceneRevision: UInt64,
                entities: [CapabilityPreparationEntity] = []) {
        self.sceneRevision = sceneRevision
        self.entities = entities
    }
}

public struct CapabilityPreview: Codable, Sendable, Equatable {
    public var summary: String
    public var targetReferences: [String]

    public init(summary: String, targetReferences: [String] = []) {
        self.summary = summary
        self.targetReferences = targetReferences
    }
}

/// The complete result of a pure built-in `prepare` call. Only host-owned
/// transaction operations can cross this boundary.
public struct PreparedCapability: Sendable, Equatable {
    public var operations: [TransactionOperation]
    public var preview: CapabilityPreview
    public var assertions: [TransactionVerificationAssertion]

    public init(operations: [TransactionOperation],
                preview: CapabilityPreview,
                assertions: [TransactionVerificationAssertion]) {
        self.operations = operations
        self.preview = preview
        self.assertions = assertions
    }
}

public protocol GuavaCapability: Sendable {
    associatedtype Input: GuavaCapabilityInput

    static var id: String { get }
    static var version: Int { get }
    static var title: String { get }
    static var description: String { get }
    static var domain: String { get }
    static var access: CapabilityAccess { get }
    static var releasePhase: CapabilityReleasePhase { get }
    static var source: CapabilitySource { get }

    static func prepare(input: Input,
                        context: CapabilityPreparationContext) throws -> PreparedCapability
}

public extension GuavaCapability {
    static var version: Int { 1 }
    static var source: CapabilitySource { .builtin }

    static var contract: CapabilityContract {
        CapabilityContract(id: id,
                           version: version,
                           title: title,
                           description: description,
                           domain: domain,
                           access: access,
                           releasePhase: releasePhase,
                           inputSchema: Input.inputSchema,
                           source: source)
    }
}

public enum CapabilityRegistrationError: Error, Sendable, Equatable, CustomStringConvertible {
    case writeSchemaMustBeStrict(String)
    case writeSchemaContainsUnsupportedType(String)
    case invalidInput(capabilityID: String, reason: String)
    case writePreparationHasNoOperations(String)
    case writePreparationHasNoPreview(String)
    case writePreparationHasNoAssertions(String)

    public var description: String {
        switch self {
        case let .writeSchemaMustBeStrict(id): return "write capability '\(id)' must use additionalProperties=false"
        case let .writeSchemaContainsUnsupportedType(id):
            return "write capability '\(id)' contains an open or unsupported schema type"
        case let .invalidInput(id, reason): return "invalid input for '\(id)': \(reason)"
        case let .writePreparationHasNoOperations(id): return "write capability '\(id)' prepared no operations"
        case let .writePreparationHasNoPreview(id): return "write capability '\(id)' prepared no preview"
        case let .writePreparationHasNoAssertions(id): return "write capability '\(id)' prepared no verification assertions"
        }
    }
}

/// Type erasure generated from a `GuavaCapability` declaration. Registry and
/// execution code never need a second decoder or provider-specific schema.
public struct AnyCapabilityRegistration: Sendable {
    public let contract: CapabilityContract
    private let prepareClosure: @Sendable (Data, CapabilityPreparationContext) throws -> PreparedCapability

    public init<C: GuavaCapability>(_ capability: C.Type) throws {
        let contract = C.contract
        if contract.access.isWrite && contract.inputSchema.additionalProperties != false {
            throw CapabilityRegistrationError.writeSchemaMustBeStrict(contract.id)
        }
        if contract.access.isWrite && !contract.inputSchema.isStrictCapabilityInput {
            throw CapabilityRegistrationError.writeSchemaContainsUnsupportedType(contract.id)
        }
        self.contract = contract
        self.prepareClosure = { data, context in
            do {
                try JSONSchemaValidator.validate(data: data, against: contract.inputSchema)
                let input = try JSONDecoder().decode(C.Input.self, from: data)
                let prepared = try C.prepare(input: input, context: context)
                if contract.access.isWrite && prepared.operations.isEmpty {
                    throw CapabilityRegistrationError.writePreparationHasNoOperations(contract.id)
                }
                if contract.access.isWrite
                    && prepared.preview.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw CapabilityRegistrationError.writePreparationHasNoPreview(contract.id)
                }
                if contract.access.isWrite && prepared.assertions.isEmpty {
                    throw CapabilityRegistrationError.writePreparationHasNoAssertions(contract.id)
                }
                return prepared
            } catch let error as CapabilityRegistrationError {
                throw error
            } catch {
                throw CapabilityRegistrationError.invalidInput(capabilityID: contract.id,
                                                               reason: String(describing: error))
            }
        }
    }

    public var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(verb: contract.id,
                             releasePhase: contract.releasePhase,
                             requiresConfirmation: contract.access.isWrite,
                             isDestructive: contract.access == .destructiveWrite,
                             domain: contract.domain,
                             version: contract.version,
                             title: contract.title,
                             description: contract.description,
                             access: contract.access,
                             inputSchema: contract.inputSchema,
                             source: contract.source,
                             isAIExposed: true)
    }

    public func prepare(validatedInput: Data,
                        context: CapabilityPreparationContext) throws -> PreparedCapability {
        try prepareClosure(validatedInput, context)
    }
}
