import Foundation

/// A project as its task plugin describes it: what can run, and sections of
/// named items such as products, targets and dependencies.
public struct TaskProjectDescription: Sendable, Equatable, Decodable {
    public struct Item: Sendable, Equatable, Decodable {
        public let name: String
        public let detail: String
    }
    public struct Section: Sendable, Equatable, Decodable {
        public let title: String
        public let items: [Item]
    }
    public let name: String
    /// Targets `run` accepts.
    public let runnables: [String]
    public let sections: [Section]
}

/// A compiler or linker message a task plugin read from output.
public struct TaskProblem: Sendable, Equatable, Identifiable, Decodable {
    public enum Severity: String, Sendable, Decodable { case error, warning, note }
    /// As printed: absolute, or relative to the project folder.
    public let file: String
    public let line: Int
    public let column: Int
    public let severity: Severity
    public let message: String
    public var id: String { "\(file):\(line):\(column):\(severity.rawValue):\(message)" }
}

public struct TaskTest: Sendable, Equatable, Identifiable, Decodable {
    public enum Status: String, Sendable, Equatable, Decodable { case notRun, running, passed, failed, skipped }
    /// `Group.Subgroup/test`: everything before the slash groups the test.
    public let id: String
    public var status: Status
    /// The first issue a failing test recorded.
    public var message: String?

    public var group: String { id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? id }
    public var name: String { id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? id }
}

public enum TaskKind: String, Sendable, Equatable {
    case build, test, run, clean, resolve
}

public struct TaskRun: Sendable, Equatable {
    public let kind: TaskKind
    /// What it ran for: a target for `run`, a test for `test`.
    public let subject: String?
    public var isRunning = true
    public var status: Int?
    public var failure: String?
    public var succeeded: Bool { !isRunning && status == 0 && failure == nil }
}

/// The project's tasks as the editor shows them.
public struct TaskSnapshot: Sendable, Equatable {
    /// The contribution whose marker the project folder holds.
    public var title: String?
    public var description: TaskProjectDescription?
    public var run: TaskRun?
    public var problems: [TaskProblem] = []
    public var tests: [TaskTest] = []

    public var isAvailable: Bool { title != nil }
}

public enum TaskOutputEvent {
    case started(TaskRun)
    case output([UInt8])
    case finished(TaskRun)
}

/// What a task plugin returns for every task but `describe`.
struct TaskReport: Decodable {
    let exit: Int
    let problems: [TaskProblem]
    let tests: [TaskTest]?
}
