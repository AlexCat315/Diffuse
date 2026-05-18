import Foundation

/// Errors thrown by `CapabilityValidator.validate`.
public enum CapabilityValidationError: Error, Sendable, Equatable {
    /// No descriptor is registered for this verb.
    case unknownVerb(String)
    /// The capability exists but is blocked by the current release phase gate.
    case phaseDenied(verb: String, reason: String)
    /// One or more preconditions were not satisfied.
    case preconditionViolations([PreconditionViolation])
}

extension CapabilityValidationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .unknownVerb(verb):
            return "unknown capability verb: '\(verb)'"
        case let .phaseDenied(_, reason):
            return reason
        case let .preconditionViolations(violations):
            let details = violations.map(\.detail).joined(separator: "; ")
            return "precondition violations: \(details)"
        }
    }
}

/// Validated result returned on success.
public struct CapabilityValidationResult: Sendable {
    public var descriptor: CapabilityDescriptor

    /// Shorthand forwarded from the descriptor.
    public var requiresConfirmation: Bool { descriptor.requiresConfirmation }
    public var isDestructive: Bool { descriptor.isDestructive }
    public var domain: String { descriptor.domain }
}

/// Top-level coordinator that combines registry lookup, phase gating, and
/// precondition evaluation into a single `validate` call.
///
/// Typical call site (IntentRuntime, before building a TransactionIR):
/// ```swift
/// let result = try validator.validate(verb: intent.verb, input: checkInput)
/// if result.requiresConfirmation { ... }
/// ```
public struct CapabilityValidator: Sendable {
    private let registry: CapabilityRegistry
    private let checker: PreconditionChecker
    private let gate: ReleasePhaseGate

    public init(registry: CapabilityRegistry = .default,
                gate: ReleasePhaseGate = ReleasePhaseGate()) {
        self.registry = registry
        self.checker = PreconditionChecker()
        self.gate = gate
    }

    // MARK: - Validation

    /// Validates that `verb` is known, phase-allowed, and all preconditions pass.
    ///
    /// - Throws: `CapabilityValidationError` on the first category of failure.
    ///   Phase denial takes priority over precondition violations.
    public func validate(verb: String,
                         input: PreconditionCheckInput) throws -> CapabilityValidationResult {
        guard let descriptor = registry.descriptor(for: verb) else {
            throw CapabilityValidationError.unknownVerb(verb)
        }
        if let reason = gate.deniedReason(for: descriptor) {
            throw CapabilityValidationError.phaseDenied(verb: verb, reason: reason)
        }
        let violations = checker.check(preconditions: descriptor.preconditions, input: input)
        if !violations.isEmpty {
            throw CapabilityValidationError.preconditionViolations(violations)
        }
        return CapabilityValidationResult(descriptor: descriptor)
    }

    /// Non-throwing variant. Returns `nil` on the first failure category and
    /// fills `errors` with details. Useful for diagnostic UIs.
    public func probe(verb: String,
                      input: PreconditionCheckInput) -> (result: CapabilityValidationResult?,
                                                         error: CapabilityValidationError?) {
        do {
            let result = try validate(verb: verb, input: input)
            return (result, nil)
        } catch let e as CapabilityValidationError {
            return (nil, e)
        } catch {
            return (nil, .unknownVerb(verb))
        }
    }
}
