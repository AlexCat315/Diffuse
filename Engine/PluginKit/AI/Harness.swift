import Swift

/// A tool call as a harness sees it: the model's request, or one the harness makes.
public struct HarnessCall {
    /// The model's identifier; pass it back so the host pairs the call with its result.
    public var id: String?
    public var name: String
    public var arguments: JSON?

    public init(id: String? = nil, name: String, arguments: JSON? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    init?(_ json: JSON?) {
        guard let name = json?["name"]?.string else { return nil }
        self.init(id: json?["id"]?.string, name: name, arguments: json?["arguments"])
    }

    var json: JSON {
        var object: JSONObject = ["name": .string(name)]
        object["id"] = id.map(JSON.string)
        object["arguments"] = arguments
        return .object(object)
    }
}

/// One step's input to a harness entry point: the `turn` it receives.
public struct HarnessTurn {
    public enum Observation {
        /// The tool the model asked for; nothing ran yet.
        case model(HarnessCall)
        /// A tool the host ran, with its result.
        case tool(HarnessCall, result: JSON)
        case failure(String)
    }

    public let step: Int
    /// What the harness returned last; nil on a fresh conversation.
    public let state: JSON?
    public let text: String
    public let locale: String
    /// The tools this turn may use: `name`, `description` and `inputSchema`.
    public let tools: [JSON]
    /// What the previous step did; nil on the first step.
    public let observation: Observation?

    public init?(_ text: String) {
        guard let object = JSON.parse(text)?.object, let step = object["step"]?.int else { return nil }
        self.step = step
        state = object["state"]
        self.text = object["request"]?["text"]?.string ?? ""
        locale = object["request"]?["locale"]?.string ?? "en"
        tools = object["tools"]?.array ?? []
        let observed = object["observation"]
        switch observed?["type"]?.string {
        case "model": observation = HarnessCall(observed?["call"]).map(Observation.model)
        case "tool": observation = HarnessCall(observed?["call"]).map { .tool($0, result: observed?["result"] ?? .null) }
        case "failure": observation = .failure(observed?["message"]?.string ?? "")
        default: observation = nil
        }
    }
}

/// What a harness returns: the next thing the host does. A nil `state` keeps the previous one.
public enum HarnessStep {
    /// Calls the model with the host's prompt plus `instructions`; `message`
    /// joins the conversation as a user message first.
    public static func model(instructions: String? = nil, message: String? = nil, state: JSON? = nil) -> String {
        var object: JSONObject = ["step": "model"]
        object["instructions"] = instructions.map(JSON.string)
        object["message"] = message.map(JSON.string)
        object["state"] = state
        return JSON.object(object).serialized
    }

    /// Runs a tool as the host's own loop would, policies and approvals included.
    public static func tool(_ call: HarnessCall, state: JSON? = nil) -> String {
        var object: JSONObject = ["step": "tool", "call": call.json]
        object["state"] = state
        return JSON.object(object).serialized
    }

    /// Ends the turn; the host refuses while drafts wait for `submit_plan`.
    public static func finish(summary: String, state: JSON? = nil) -> String {
        var object: JSONObject = ["step": "finish", "summary": .string(summary)]
        object["state"] = state
        return JSON.object(object).serialized
    }
}
