import Foundation
import PluginRuntime

/// Drives a turn in place of the built-in loop. Given what just happened, it
/// says what the session does next; the session alone calls the model and
/// runs tools, so tool policies, drafts and approvals still apply.
public typealias SessionHarness = @Sendable (SessionHarnessTurn) async throws -> SessionHarnessStep

/// What a harness sees at each step.
public struct SessionHarnessTurn: Encodable, Sendable {
    public struct Request: Encodable, Sendable, Equatable {
        public var text: String
        public var locale: String

        public init(text: String, locale: String) {
            self.text = text
            self.locale = locale
        }
    }

    public struct Tool: Encodable, Sendable, Equatable {
        public var name: String
        public var description: String
        public var inputSchema: PluginJSON?

        public init(name: String, description: String, inputSchema: PluginJSON? = nil) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
        }
    }

    public struct Call: Codable, Sendable, Equatable {
        /// The model's identifier for the call; a harness may leave it out.
        public var id: String?
        public var name: String
        public var arguments: PluginJSON?

        public init(id: String? = nil, name: String, arguments: PluginJSON? = nil) {
            self.id = id
            self.name = name
            self.arguments = arguments
        }
    }

    public enum Observation: Sendable, Equatable {
        /// The tool the model asked for; not run yet.
        case model(Call)
        /// A tool the session ran, with its result.
        case tool(Call, result: PluginJSON)
        case failure(String)
    }

    public var step: Int
    public var state: PluginJSON?
    public var request: Request
    public var tools: [Tool]
    public var observation: Observation?

    public init(step: Int, state: PluginJSON?, request: Request, tools: [Tool], observation: Observation?) {
        self.step = step
        self.state = state
        self.request = request
        self.tools = tools
        self.observation = observation
    }

    private enum Keys: String, CodingKey { case step, state, request, tools, observation, type, call, result, message }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(step, forKey: .step)
        try c.encodeIfPresent(state, forKey: .state)
        try c.encode(request, forKey: .request)
        try c.encode(tools, forKey: .tools)
        guard let observation else { return }
        var o = c.nestedContainer(keyedBy: Keys.self, forKey: .observation)
        switch observation {
        case let .model(call):
            try o.encode("model", forKey: .type)
            try o.encode(call, forKey: .call)
        case let .tool(call, result):
            try o.encode("tool", forKey: .type)
            try o.encode(call, forKey: .call)
            try o.encode(result, forKey: .result)
        case let .failure(message):
            try o.encode("failure", forKey: .type)
            try o.encode(message, forKey: .message)
        }
    }
}

/// What a harness asks the session to do next.
public struct SessionHarnessStep: Decodable, Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// Call the model with the session's prompt plus `instructions`;
        /// `message` joins the conversation as a user message first.
        case model(instructions: String?, message: String?)
        /// Run a tool as the built-in loop would.
        case tool(SessionHarnessTurn.Call)
        /// End the turn with a summary. Refused while drafts wait for `submit_plan`.
        case finish(summary: String)
    }

    public var action: Action
    /// Nil keeps the previous state.
    public var state: PluginJSON?

    public init(_ action: Action, state: PluginJSON? = nil) {
        self.action = action
        self.state = state
    }

    private enum Keys: String, CodingKey { case step, instructions, message, call, summary, state }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        state = try c.decodeIfPresent(PluginJSON.self, forKey: .state)
        switch try c.decode(String.self, forKey: .step) {
        case "model":
            action = .model(instructions: try c.decodeIfPresent(String.self, forKey: .instructions),
                            message: try c.decodeIfPresent(String.self, forKey: .message))
        case "tool":
            action = .tool(try c.decode(SessionHarnessTurn.Call.self, forKey: .call))
        case "finish":
            action = .finish(summary: try c.decode(String.self, forKey: .summary))
        default:
            throw DecodingError.dataCorruptedError(forKey: .step, in: c, debugDescription: "unknown harness step")
        }
    }

    /// The most steps one turn may take.
    public static let maximumSteps = 32
}

/// The harness of the current conversation and what it carries between steps.
struct SessionHarnessState {
    var harness: SessionHarness?
    /// Which harness `state` belongs to.
    var id: String?
    var state: PluginJSON?
    var request = SessionHarnessTurn.Request(text: "", locale: "en")
    /// Added to the system prompt for the model call a harness asked for.
    var instructions: String?
}
