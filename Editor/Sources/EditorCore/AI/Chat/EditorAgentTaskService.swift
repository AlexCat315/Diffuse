import Foundation
import AIRuntime

public enum EditorAgentTaskPhase: String, Sendable, Equatable {
    case planning, awaitingReview, applied, completed, discarded, failed, cancelled, conflict

    public var isTerminal: Bool { self != .planning && self != .awaitingReview }
    public var title: String {
        switch self {
        case .planning: "Planning"
        case .awaitingReview: "Awaiting Review"
        case .applied: "Applied"
        case .completed: "Completed"
        case .discarded: "Discarded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .conflict: "Scene Changed"
        }
    }
}

public struct EditorAgentTaskTarget: Sendable, Equatable {
    public let documentID: UUID
    public let sceneRevision: UInt64
    public let workspace: EditorWorkspaceMode
    public let selectedEntityIDs: Set<UInt64>
    public let primaryEntityID: UInt64?

    public init(documentID: UUID, sceneRevision: UInt64, workspace: EditorWorkspaceMode,
                selectedEntityIDs: Set<UInt64>, primaryEntityID: UInt64?) {
        self.documentID = documentID
        self.sceneRevision = sceneRevision
        self.workspace = workspace
        self.selectedEntityIDs = selectedEntityIDs
        self.primaryEntityID = primaryEntityID
    }

    public func matches(documentID: UUID, sceneRevision: UInt64) -> Bool {
        self.documentID == documentID && self.sceneRevision == sceneRevision
    }
}

public struct EditorAgentTask: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let prompt: String
    public let target: EditorAgentTaskTarget
    public var phase: EditorAgentTaskPhase = .planning
    public var summary: String = ""

    public init(id: UUID = UUID(), prompt: String, target: EditorAgentTaskTarget) {
        self.id = id
        self.prompt = prompt
        self.target = target
    }
}

/// A UI-independent task lifecycle. The two shells consume its snapshots and
/// share the existing transaction/confirmation pipeline.
public final class EditorAgentTaskService {
    public private(set) var tasks: [EditorAgentTask] = []
    public private(set) var activeTaskID: UUID?
    public var activeTask: EditorAgentTask? { tasks.first { $0.id == activeTaskID } }

    public init() {}

    @discardableResult
    public func begin(prompt: String, target: EditorAgentTaskTarget) -> EditorAgentTask? {
        guard activeTaskID == nil else { return nil }
        let task = EditorAgentTask(prompt: prompt, target: target)
        tasks.insert(task, at: 0)
        tasks = Array(tasks.prefix(40))
        activeTaskID = task.id
        return task
    }

    public func transition(to phase: EditorAgentTaskPhase, summary: String = "") {
        guard let index = tasks.firstIndex(where: { $0.id == activeTaskID }) else { return }
        tasks[index].phase = phase
        tasks[index].summary = summary
        if phase.isTerminal { activeTaskID = nil }
    }
}

/// Transport handles stay separate from the task read model and preferences.
struct EditorAgentExecution {
    var requestID: UUID?
    var requestTask: Task<Void, Never>?
    var proposal: Proposal?
    var assistantMessageID: String?
    var confirmationTargetEntityIDs: Set<UInt64> = []
}
