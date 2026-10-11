import GuavaUIRuntime

/// Authored workflow outcomes are independent from the current destination.
/// Going back to an earlier step never silently rewrites a later outcome.
public enum StepStatus: String, Sendable, Codable, CaseIterable {
    case pending, inProgress, completed, failed
    var description: String {
        switch self {
        case .pending: "Not completed"
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }
    var tone: StatusTone {
        switch self {
        case .pending: .neutral
        case .inProgress: .info
        case .completed: .success
        case .failed: .danger
        }
    }
}

public struct StepperItem<ID: Hashable>: Identifiable {
    public let id: ID
    public let title: String
    public var detail = ""
    public var status: StepStatus = .pending
    public var isEnabled = true
    public init(_ id: ID, _ title: String, configure: (inout Self) -> Void = { _ in }) {
        self.id = id; self.title = title; configure(&self)
    }
}

public enum StepperAxis: Sendable, Equatable { case horizontal, vertical }

public struct StepperOptions {
    public var axis: StepperAxis = .horizontal
    public var isEnabled = true
    public var allowsWrap = false
    public var label = "Steps"
    public init() {}
}
