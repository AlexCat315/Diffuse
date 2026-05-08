import Foundation
import IntentRuntime

/// AI's structured change intent produced by Session.
///
/// Callers convert a Proposal to a `TransactionIR` using `SceneEditPlanExecutor`,
/// which needs a live `SceneRuntime` — available in EditorCore but not inside AIRuntime.
public struct Proposal: Sendable, Identifiable {
    public var id: String
    public var sessionID: String
    public var semanticIntent: String
    public var plan: SceneEditPlan
    public var baseSceneRevision: UInt64?
    public var reasoning: String?
    public var confidence: Double
    public var approvalPolicy: TransactionApprovalPolicy
    public var createdAt: Date

    public init(id: String = UUID().uuidString,
                sessionID: String,
                semanticIntent: String,
                plan: SceneEditPlan,
                baseSceneRevision: UInt64? = nil,
                reasoning: String? = nil,
                confidence: Double = 0.85,
                approvalPolicy: TransactionApprovalPolicy = .requiresApproval,
                createdAt: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.semanticIntent = semanticIntent
        self.plan = plan
        self.baseSceneRevision = baseSceneRevision
        self.reasoning = reasoning
        self.confidence = confidence
        self.approvalPolicy = approvalPolicy
        self.createdAt = createdAt
    }
}
