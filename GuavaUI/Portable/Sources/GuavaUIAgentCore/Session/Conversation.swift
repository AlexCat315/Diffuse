import Foundation

public struct AgentToolCall: Sendable {
    public let id: String
    public let name: String
    public let arguments: Data
    public init(id: String, name: String, arguments: Data) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

public struct AgentMessage: Sendable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public let role: Role
    public let text: String
    public let calls: [AgentToolCall]
    public let resultFor: String?
    public let isError: Bool
    public init(role: Role, text: String = "", calls: [AgentToolCall] = [], resultFor: String? = nil, isError: Bool = false) {
        self.role = role; self.text = text; self.calls = calls; self.resultFor = resultFor; self.isError = isError
    }
}

public enum AgentReply: Sendable {
    case answer(String)
    case tools([AgentToolCall])
}

public struct AgentRun: Sendable {
    public let answer: String
    public let messages: [AgentMessage]
    public let toolRounds: Int
}

/// A provider-neutral tool loop. A model adapter accepts ordinary messages and
/// descriptors; the application supplies its existing data/functions as tools.
public struct AgentSession: Sendable {
    public typealias Model = @Sendable ([AgentMessage], [AgentTool]) async throws -> AgentReply
    private let model: Model
    private let toolbox: AgentToolbox
    private let instructions: String
    private let maximumToolRounds: Int

    public init(toolbox: AgentToolbox, skills: AgentSkillLibrary = AgentSkillLibrary(),
                enabledSkills: [String] = [], maximumToolRounds: Int = 8, model: @escaping Model) throws {
        self.toolbox = toolbox
        self.instructions = try skills.instructions(for: enabledSkills)
        self.maximumToolRounds = max(1, min(32, maximumToolRounds))
        self.model = model
    }

    public func run(messages input: [AgentMessage]) async throws -> AgentRun {
        var messages = input
        if !instructions.isEmpty { messages.insert(AgentMessage(role: .system, text: instructions), at: 0) }
        for round in 0...maximumToolRounds {
            try Task.checkCancellation()
            guard messages.count <= 256, messages.reduce(0, { $0 + $1.text.utf8.count }) <= 1_048_576 else {
                throw AgentError.invalidConfiguration("Conversation exceeds the message or byte limit.")
            }
            let reply = try await model(messages, toolbox.tools)
            try Task.checkCancellation()
            switch reply {
            case .answer(let text):
                guard text.utf8.count <= 262_144 else { throw AgentError.invalidResult }
                messages.append(AgentMessage(role: .assistant, text: text))
                return AgentRun(answer: text, messages: messages, toolRounds: round)
            case .tools(let calls):
                guard round < maximumToolRounds else { throw AgentError.stepLimit }
                guard !calls.isEmpty, calls.count <= 16, Set(calls.map(\.id)).count == calls.count,
                      calls.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 }) else {
                    throw AgentError.invalidConfiguration("Model returned invalid tool calls.")
                }
                messages.append(AgentMessage(role: .assistant, calls: calls))
                for call in calls {
                    let result: AgentToolResult
                    do { result = try await toolbox.execute(name: call.name, input: call.arguments) }
                    catch is CancellationError { throw CancellationError() }
                    catch { result = try AgentToolResult.encode(["error": String(error.localizedDescription.prefix(4096))], isError: true) }
                    messages.append(AgentMessage(role: .tool, text: String(decoding: result.json, as: UTF8.self),
                        resultFor: call.id, isError: result.isError))
                }
            }
        }
        throw AgentError.stepLimit
    }
}
