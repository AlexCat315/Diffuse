import Foundation

/// Transport-neutral MCP endpoint. Stdio, sockets and embedded hosts pass JSON
/// bytes in and receive response bytes out; no globals or process ownership.
public actor MCPServer {
    public typealias Tools = @Sendable () async throws -> [AgentTool]
    private let name: String
    private let version: String
    private let listTools: Tools
    private let executor: AgentToolbox.Executor
    private let skills: AgentSkillLibrary
    private let toolsMayChange: Bool

    public init(name: String, version: String, toolbox: AgentToolbox,
                skills: AgentSkillLibrary = AgentSkillLibrary()) {
        self.name = name; self.version = version; self.listTools = { toolbox.tools }
        self.executor = { try await toolbox.execute(name: $0, input: $1) }
        self.skills = skills; self.toolsMayChange = false
    }

    public init(name: String, version: String, skills: AgentSkillLibrary = AgentSkillLibrary(),
                tools: @escaping Tools, execute: @escaping AgentToolbox.Executor) {
        self.name = name; self.version = version; self.skills = skills
        self.listTools = tools; self.executor = execute; self.toolsMayChange = true
    }

    public func respond(to data: Data) async -> Data? {
        guard data.count <= 1_048_576 else { return error(id: NSNull(), code: -32600, message: "Request exceeds 1 MiB.") }
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return error(id: NSNull(), code: -32700, message: "Invalid JSON.")
        }
        guard let request = value as? [String: Any] else {
            return error(id: NSNull(), code: -32600, message: "Invalid JSON-RPC request.")
        }
        let rawID = request["id"] ?? NSNull()
        let idSchema = JSONSchema(oneOf: [.string(), .init(type: .number)])
        let validID = rawID is NSNull || (try? JSONSchemaValidator.validate(rawID, against: idSchema)) != nil
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            return error(id: validID ? rawID : NSNull(), code: -32600, message: "Invalid JSON-RPC request.")
        }
        guard let id = request["id"] else { return nil }
        guard validID else {
            return error(id: NSNull(), code: -32600, message: "Invalid request ID.")
        }
        guard request["params"] == nil || request["params"] is [String: Any] else {
            return error(id: id, code: -32602, message: "Parameters must be an object.")
        }
        let params = request["params"] as? [String: Any] ?? [:]
        do { return try await dispatch(method, params: params, id: id) }
        catch is CancellationError { return error(id: id, code: -32800, message: "Request cancelled.") }
        catch { return self.error(id: id, code: -32602, message: String(error.localizedDescription.prefix(4096))) }
    }

    private func dispatch(_ method: String, params: [String: Any], id: Any) async throws -> Data {
        switch method {
        case "initialize":
            let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            let requested = params["protocolVersion"] as? String ?? ""
            return response(id: id, result: ["protocolVersion": versions.contains(requested) ? requested : versions[0],
                "serverInfo": ["name": name, "version": version],
                "capabilities": ["tools": ["listChanged": toolsMayChange], "prompts": [:]]])
        case "ping": return response(id: id, result: [:])
        case "tools/list":
            let tools = try await listTools()
            _ = try AgentToolbox(tools: tools, execute: executor)
            return response(id: id, result: ["tools": tools.map(\.mcpDefinition)])
        case "tools/call":
            guard let toolName = params["name"] as? String,
                  params["arguments"] == nil || params["arguments"] is [String: Any] else {
                return error(id: id, code: -32602, message: "tools/call requires a name and object arguments.")
            }
            let toolbox = try AgentToolbox(tools: await listTools(), execute: executor)
            let input = try JSONSerialization.data(withJSONObject: params["arguments"] ?? [:])
            do {
                let output = try await toolbox.execute(name: toolName, input: input)
                let value = try JSONSerialization.jsonObject(with: output.json, options: [.fragmentsAllowed])
                var result: [String: Any] = ["content": [["type": "text", "text": String(decoding: output.json, as: UTF8.self)]],
                                            "isError": output.isError]
                if let object = value as? [String: Any] { result["structuredContent"] = object }
                return response(id: id, result: result)
            } catch is CancellationError { throw CancellationError() }
            catch {
                return response(id: id, result: ["content": [["type": "text", "text": String(error.localizedDescription.prefix(4096))]], "isError": true])
            }
        case "prompts/list":
            return response(id: id, result: ["prompts": skills.skills.map { ["name": $0.name, "description": $0.description] }])
        case "prompts/get":
            let skill = try skills.read(name: params["name"] as? String ?? "")
            return response(id: id, result: ["description": skill.description,
                "messages": [["role": "user", "content": ["type": "text", "text": skill.instructions]]]])
        default: return error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func response(id: Any, result: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }
    private func error(id: Any, code: Int, message: String) -> Data {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }
    private func encode(_ value: [String: Any]) -> Data {
        // All values originate from validated JSON or bounded framework metadata.
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
    }
}
