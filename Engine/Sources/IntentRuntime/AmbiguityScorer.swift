import CapabilityRuntime
import Foundation

/// Categorises the degree of ambiguity in an `IntentIR` so the coordinator can
/// decide whether to apply immediately, surface a clarification question, or
/// route to the full confirmation flow.
public enum AmbiguityLevel: String, Sendable, Equatable, Comparable, CaseIterable {
    /// Intent is fully specified; apply immediately (no confirmation needed beyond
    /// policy requirements).
    case clear = "clear"
    /// Some parameters are inferred or defaulted; worth surfacing a brief
    /// summary before applying.
    case low = "low"
    /// Multiple interpretations are plausible; ask the user to choose.
    case medium = "medium"
    /// Target, scope, or outcome is genuinely unclear; block and ask.
    case high = "high"

    private var order: Int {
        switch self { case .clear: 0; case .low: 1; case .medium: 2; case .high: 3 }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

/// A single factor that raised the ambiguity score.
public struct AmbiguitySignal: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// The intent confidence value is below the threshold.
        case lowConfidence = "low_confidence"
        /// No target entity was specified and no entity is selected.
        case noTarget = "no_target"
        /// More than one candidate entity could be the target.
        case multipleTargets = "multiple_targets"
        /// A required argument is absent (verb needs it, but it wasn't provided).
        case missingRequiredArgument = "missing_required_argument"
        /// The verb is destructive (always adds a signal; policy may override).
        case destructiveVerb = "destructive_verb"
        /// Intent came from an AI source at less-than-full confidence.
        case aiLowConfidence = "ai_low_confidence"
        /// Evidence list is empty, so we cannot verify the intent is grounded.
        case noEvidence = "no_evidence"
    }

    public var kind: Kind
    /// A compact note surfaced in the confirmation UI or debug log.
    public var note: String
    /// Contribution to the 0...1 score (before clamping).
    public var weight: Double

    public init(kind: Kind, note: String, weight: Double) {
        self.kind = kind
        self.note = note
        self.weight = weight
    }
}

/// Result of scoring one `IntentIR`.
public struct AmbiguityScore: Sendable, Equatable {
    /// Composite score in [0, 1]; higher means more ambiguous.
    public var score: Double
    /// Discrete level derived from `score`.
    public var level: AmbiguityLevel
    /// All signals that contributed to the score.
    public var signals: [AmbiguitySignal]

    public init(score: Double, level: AmbiguityLevel, signals: [AmbiguitySignal]) {
        self.score = score
        self.level = level
        self.signals = signals
    }
}

/// Weights and thresholds used by `AmbiguityScorer`.
public struct AmbiguityScorerConfig: Sendable {
    /// Score at or above this maps to `.high`.
    public var highThreshold: Double
    /// Score at or above this maps to `.medium`.
    public var mediumThreshold: Double
    /// Score at or above this maps to `.low`.
    public var lowThreshold: Double

    /// Confidence below this raises `lowConfidence`.
    public var confidenceFloor: Double

    public static let `default` = AmbiguityScorerConfig(
        highThreshold: 0.65,
        mediumThreshold: 0.40,
        lowThreshold: 0.15,
        confidenceFloor: 0.75
    )

    public init(highThreshold: Double,
                mediumThreshold: Double,
                lowThreshold: Double,
                confidenceFloor: Double) {
        self.highThreshold = highThreshold
        self.mediumThreshold = mediumThreshold
        self.lowThreshold = lowThreshold
        self.confidenceFloor = confidenceFloor
    }
}

/// Context supplied by the caller when scoring an `IntentIR`.
public struct AmbiguityScoringContext: Sendable {
    /// IDs present in the scene that could plausibly match the intent.
    public var candidateEntityIDs: [UInt64]
    /// The editor selection available as a fallback target.
    public var selectedEntityID: UInt64?
    /// Whether this verb needs a target entity.
    public var requiresTarget: Bool
    /// Whether the intent's verb is registered as destructive.
    public var isVerbDestructive: Bool
    /// Argument keys that the verb's capability descriptor requires.
    public var requiredArgumentNames: Set<String>

    public init(candidateEntityIDs: [UInt64] = [],
                selectedEntityID: UInt64? = nil,
                requiresTarget: Bool = false,
                isVerbDestructive: Bool = false,
                requiredArgumentNames: Set<String> = []) {
        self.candidateEntityIDs = candidateEntityIDs
        self.selectedEntityID = selectedEntityID
        self.requiresTarget = requiresTarget
        self.isVerbDestructive = isVerbDestructive
        self.requiredArgumentNames = requiredArgumentNames
    }

    public init(descriptor: CapabilityDescriptor,
                candidateEntityIDs: [UInt64] = [],
                selectedEntityID: UInt64? = nil) {
        self.init(candidateEntityIDs: candidateEntityIDs,
                  selectedEntityID: selectedEntityID,
                  requiresTarget: descriptor.requiresTargetEntity,
                  isVerbDestructive: descriptor.isDestructive,
                  requiredArgumentNames: descriptor.requiredArgumentNames)
    }
}

/// Stateless scorer.  Create once and reuse across many intents.
public struct AmbiguityScorer: Sendable {
    public var config: AmbiguityScorerConfig

    public init(config: AmbiguityScorerConfig = .default) {
        self.config = config
    }

    // MARK: - Scoring

    public func score(_ intent: IntentIR,
                      context: AmbiguityScoringContext) -> AmbiguityScore {
        var signals: [AmbiguitySignal] = []
        var raw = 0.0

        // Confidence.
        let confidenceFloor = max(config.confidenceFloor, Double.ulpOfOne)
        let confidence = min(1.0, max(0.0, intent.confidence))
        if intent.source == .ai && confidence < confidenceFloor {
            let weight = 0.35 * (1 - confidence / confidenceFloor)
            signals.append(AmbiguitySignal(
                kind: .aiLowConfidence,
                note: "AI confidence \(String(format: "%.0f", confidence * 100))% < floor \(String(format: "%.0f", confidenceFloor * 100))%",
                weight: weight
            ))
            raw += weight
        } else if confidence < confidenceFloor {
            let weight = 0.25 * (1 - confidence / confidenceFloor)
            signals.append(AmbiguitySignal(
                kind: .lowConfidence,
                note: "confidence \(String(format: "%.0f", confidence * 100))% < floor",
                weight: weight
            ))
            raw += weight
        }

        // Target and selection.
        if intent.targetObjectIDs.count > 1 {
            let weight = 0.20
            signals.append(AmbiguitySignal(
                kind: .multipleTargets,
                note: "\(intent.targetObjectIDs.count) explicit targetObjectIDs",
                weight: weight
            ))
            raw += weight
        } else if context.requiresTarget,
                  intent.targetObjectIDs.isEmpty,
                  context.selectedEntityID == nil {
            if context.candidateEntityIDs.count > 1 {
                let weight = 0.25
                signals.append(AmbiguitySignal(
                    kind: .multipleTargets,
                    note: "\(context.candidateEntityIDs.count) candidate targets",
                    weight: weight
                ))
                raw += weight
            } else if context.candidateEntityIDs.count == 1 {
                let weight = 0.10
                signals.append(AmbiguitySignal(
                    kind: .noTarget,
                    note: "target must be inferred from one candidate",
                    weight: weight
                ))
                raw += weight
            } else {
                let weight = 0.30
                signals.append(AmbiguitySignal(
                    kind: .noTarget,
                    note: "no targetObjectIDs specified",
                    weight: weight
                ))
                raw += weight
            }
        }

        // Missing required arguments.
        let providedArgs = Set(intent.arguments.keys)
        let missing = context.requiredArgumentNames.subtracting(providedArgs)
        if !missing.isEmpty {
            let weight = 0.20 * Double(missing.count)
            signals.append(AmbiguitySignal(
                kind: .missingRequiredArgument,
                note: "missing: \(missing.sorted().joined(separator: ", "))",
                weight: weight
            ))
            raw += weight
        }

        // Destructive verbs require a confirmation affordance even when their
        // target and arguments are otherwise clear.
        if context.isVerbDestructive {
            signals.append(AmbiguitySignal(
                kind: .destructiveVerb,
                note: "verb '\(intent.verb)' is marked destructive",
                weight: 0.15
            ))
            raw += 0.15
        }

        // Evidence is only required for AI-authored intents.
        if intent.source == .ai && intent.evidence.isEmpty {
            signals.append(AmbiguitySignal(
                kind: .noEvidence,
                note: "no evidence attached to intent",
                weight: 0.10
            ))
            raw += 0.10
        }

        let clamped = min(1.0, max(0.0, raw))
        let level: AmbiguityLevel
        if clamped >= config.highThreshold {
            level = .high
        } else if clamped >= config.mediumThreshold {
            level = .medium
        } else if clamped >= config.lowThreshold {
            level = .low
        } else {
            level = .clear
        }

        return AmbiguityScore(score: clamped, level: level, signals: signals)
    }

    // MARK: - Question generation

    /// Produces a `ConfirmationQuestion` from a high-ambiguity score.
    /// Returns `nil` when `level` is `.clear` (no confirmation needed).
    public func makeQuestion(for intent: IntentIR,
                             score: AmbiguityScore,
                             options: [ConfirmationOption] = []) -> ConfirmationQuestion? {
        guard score.level >= .low else { return nil }
        let noteLines = score.signals.map { "- \($0.note)" }.joined(separator: "\n")
        let hasDestructiveSignal = score.signals.contains { $0.kind == .destructiveVerb }
        let promptDetail = noteLines.isEmpty
            ? "Ambiguity: \(score.level.rawValue)"
            : "Ambiguity: \(score.level.rawValue)\n\(noteLines)"
        return ConfirmationQuestion(
            id: "ambiguity:\(intent.id)",
            kind: hasDestructiveSignal ? .approveDestructive : .chooseOne,
            promptShort: intent.summary.isEmpty ? "Confirm: \(intent.verb)" : intent.summary,
            promptDetail: promptDetail,
            options: options.isEmpty ? defaultOptions(for: intent) : options,
            defaultOptionID: "apply",
            severity: hasDestructiveSignal ? .destructive : (score.level >= .high ? .warn : .info),
            reversible: true,
            ambiguityScore: score.score,
            sourceProposalIDs: [intent.id]
        )
    }

    private func defaultOptions(for intent: IntentIR) -> [ConfirmationOption] {
        [
            ConfirmationOption(id: "apply",
                               labelShort: "Apply",
                               labelDetail: "Proceed with '\(intent.verb)'"),
            ConfirmationOption(id: "reject",
                               labelShort: "Reject",
                               labelDetail: "Discard this intent"),
        ]
    }
}
