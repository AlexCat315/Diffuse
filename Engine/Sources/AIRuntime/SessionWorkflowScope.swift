import CapabilityRuntime

/// Captured for a request. Provider transports and tool discovery use the same
/// authority set; selection stays bound while the visible shell changes.
public struct SessionWorkflowScope: Sendable {
    public var context: WorkflowContext?
    public var allowedCapabilityIDs: Set<String>?
    public var allowedProjectToolNames: Set<String>?
    public var selectedEntityRefs: [String]?

    public init(_ configure: (inout Self) -> Void = { _ in }) { configure(&self) }

    func restricting(_ policy: CapabilityExposurePolicy) -> CapabilityExposurePolicy {
        var result = policy
        if let ids = allowedCapabilityIDs {
            result.allowedCapabilityIDs = policy.allowedCapabilityIDs.map { $0.intersection(ids) } ?? ids
        }
        return result
    }
}
