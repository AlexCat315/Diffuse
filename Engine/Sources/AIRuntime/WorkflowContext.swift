import Foundation

// MARK: - Game workflow

public struct PlaytestSummary: Sendable, Equatable, Codable {
    public var sessionDate: Date
    public var playerCount: Int
    public var observations: [String]

    public init(sessionDate: Date = Date(), playerCount: Int = 1, observations: [String]) {
        self.sessionDate = sessionDate
        self.playerCount = playerCount
        self.observations = observations
    }
}

public enum GameLevelPhase: String, Sendable, Equatable, Codable, CustomStringConvertible {
    case blockout = "Blockout"
    case encounterDesign = "EncounterDesign"
    case polish = "Polish"
    case balance = "Balance"
    case ship = "Ship"

    public var description: String { rawValue }
}

public struct GameplayIntent: Sendable, Equatable, Codable {
    public var genre: String
    public var winCondition: String
    public var playerCount: Int
    public var pacing: String

    public init(genre: String,
                winCondition: String,
                playerCount: Int = 1,
                pacing: String = "exploration") {
        self.genre = genre
        self.winCondition = winCondition
        self.playerCount = playerCount
        self.pacing = pacing
    }
}

public struct GameKnownConstraints: Sendable, Equatable, Codable {
    public var navMeshBaked: Bool
    public var performanceBudget: String
    public var scriptingRegistry: [String]

    public init(navMeshBaked: Bool = false,
                performanceBudget: String = "console_high",
                scriptingRegistry: [String] = []) {
        self.navMeshBaked = navMeshBaked
        self.performanceBudget = performanceBudget
        self.scriptingRegistry = scriptingRegistry
    }
}

/// Workflow context for interactive / game projects. Shapes Session's system prompt
/// so it reasons about player experience, encounter design, and level pacing.
public struct GameWorkflowContext: Sendable, Equatable, Codable {
    public var levelPhase: GameLevelPhase
    public var gameplayIntent: GameplayIntent
    public var targetExperience: String
    public var knownConstraints: GameKnownConstraints
    public var playtestObservations: [PlaytestSummary]

    public init(levelPhase: GameLevelPhase = .blockout,
                gameplayIntent: GameplayIntent,
                targetExperience: String,
                knownConstraints: GameKnownConstraints = GameKnownConstraints(),
                playtestObservations: [PlaytestSummary] = []) {
        self.levelPhase = levelPhase
        self.gameplayIntent = gameplayIntent
        self.targetExperience = targetExperience
        self.knownConstraints = knownConstraints
        self.playtestObservations = playtestObservations
    }

    var systemPromptSection: String {
        var lines: [String] = [
            "Workflow: game/interactive project",
            "Level phase: \(levelPhase)",
            "Genre: \(gameplayIntent.genre) | Win condition: \(gameplayIntent.winCondition) | Pacing: \(gameplayIntent.pacing) | Players: \(gameplayIntent.playerCount)",
            "Target experience: \(targetExperience)",
            "Performance budget: \(knownConstraints.performanceBudget)",
        ]
        if knownConstraints.navMeshBaked {
            lines.append("NavMesh is baked — you can reason about traversability.")
        }
        if !knownConstraints.scriptingRegistry.isEmpty {
            lines.append("Registered gameplay actions: \(knownConstraints.scriptingRegistry.joined(separator: ", "))")
        }
        if !playtestObservations.isEmpty {
            let recent = playtestObservations.suffix(3).flatMap(\.observations)
            if !recent.isEmpty {
                lines.append("Recent playtest observations: " + recent.joined(separator: "; "))
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Film workflow

public enum FilmNarrativePhase: String, Sendable, Equatable, Codable, CustomStringConvertible {
    case blocking
    case performance
    case cameraLanguage = "camera_language"
    case lighting
    case review

    public var description: String { rawValue }

    /// Approval policy constraint for this phase. `nil` means the default policy applies.
    var requiresStrictApproval: Bool {
        self == .review
    }
}

public struct ReferenceAnchor: Sendable, Equatable, Codable {
    public var uri: String
    public var semanticSummary: String
    public var addedAt: Date

    public init(uri: String, semanticSummary: String, addedAt: Date = Date()) {
        self.uri = uri
        self.semanticSummary = semanticSummary
        self.addedAt = addedAt
    }
}

/// Workflow context for cinematic / film projects. Shapes Session's reasoning around
/// narrative intent, shot language, and phase-appropriate approval policies.
public struct FilmWorkflowContext: Sendable, Equatable, Codable {
    public var activeSequenceID: String
    public var activeShotID: String?
    public var narrativePhase: FilmNarrativePhase
    public var directorIntent: String?
    public var referenceAnchors: [ReferenceAnchor]
    public var lockedShotIDs: [String]

    public init(activeSequenceID: String,
                activeShotID: String? = nil,
                narrativePhase: FilmNarrativePhase = .blocking,
                directorIntent: String? = nil,
                referenceAnchors: [ReferenceAnchor] = [],
                lockedShotIDs: [String] = []) {
        self.activeSequenceID = activeSequenceID
        self.activeShotID = activeShotID
        self.narrativePhase = narrativePhase
        self.directorIntent = directorIntent
        self.referenceAnchors = referenceAnchors
        self.lockedShotIDs = lockedShotIDs
    }

    var systemPromptSection: String {
        var lines: [String] = [
            "Workflow: cinematic / film project",
            "Narrative phase: \(narrativePhase)",
            "Active sequence: \(activeSequenceID)",
        ]
        if let shot = activeShotID {
            lines.append("Active shot: \(shot)")
        }
        if let intent = directorIntent, !intent.isEmpty {
            lines.append("Director intent: \(intent)")
        }
        if !lockedShotIDs.isEmpty {
            lines.append("Locked shots (do not modify): \(lockedShotIDs.joined(separator: ", "))")
        }
        if narrativePhase.requiresStrictApproval {
            lines.append("Review phase: all proposals require explicit approval — never use automatic mode.")
        }
        if !referenceAnchors.isEmpty {
            let summaries = referenceAnchors.map { "[\($0.uri): \($0.semanticSummary)]" }
            lines.append("Reference anchors: " + summaries.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Unified WorkflowContext

public enum WorkflowContext: Sendable, Equatable, Codable {
    case game(GameWorkflowContext)
    case film(FilmWorkflowContext)

    var systemPromptSection: String {
        switch self {
        case let .game(ctx): return ctx.systemPromptSection
        case let .film(ctx): return ctx.systemPromptSection
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, payload }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "game": self = .game(try c.decode(GameWorkflowContext.self, forKey: .payload))
        case "film": self = .film(try c.decode(FilmWorkflowContext.self, forKey: .payload))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                         debugDescription: "unknown WorkflowContext kind '\(kind)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .game(ctx):
            try c.encode("game", forKey: .kind)
            try c.encode(ctx, forKey: .payload)
        case let .film(ctx):
            try c.encode("film", forKey: .kind)
            try c.encode(ctx, forKey: .payload)
        }
    }
}
