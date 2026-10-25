import CapabilityRuntime

/// Captured for a request. Provider transports and tool discovery use the same
/// authority set; selection stays bound while the visible shell changes.
public struct SessionWorkflowScope: Sendable {
    public var context: WorkflowContext?
    public var allowedCapabilityIDs: Set<String>?
    public var allowedProjectToolNames: Set<String>?
    public var selectedEntityRefs: [String]?
    public var agent = SessionAgentContext()

    public init(_ configure: (inout Self) -> Void = { _ in }) { configure(&self) }

    func restricting(_ policy: CapabilityExposurePolicy) -> CapabilityExposurePolicy {
        var result = policy
        if let ids = allowedCapabilityIDs {
            result.allowedCapabilityIDs = policy.allowedCapabilityIDs.map { $0.intersection(ids) } ?? ids
        }
        return result
    }
}

/// A host source of model context an agent may leave out.
public enum SessionContextSource: String, Sendable, CaseIterable {
    case scene, selection, edits, memory, transactions, workflow, assets
}

/// Text from outside the session, such as a plugin's context, sent with the request.
public struct SessionContextSection: Sendable, Equatable {
    public var title: String
    public var text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

/// What the active agent adds to and keeps out of a request. The host's own
/// instructions and rules always remain.
public struct SessionAgentContext: Sendable, Equatable {
    public var instructions: String?
    /// The host sources the agent sees; nil means all of them.
    public var sources: Set<SessionContextSource>?
    public var sections: [SessionContextSection] = []

    public init(instructions: String? = nil, sources: Set<SessionContextSource>? = nil,
                sections: [SessionContextSection] = []) {
        self.instructions = instructions
        self.sources = sources
        self.sections = sections
    }

    public func includes(_ source: SessionContextSource) -> Bool { sources?.contains(source) ?? true }
}
