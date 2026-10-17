public import Foundation
public import GuavaUIAgentCore
public import GuavaUIDevToolsProtocol

public extension UIDiagnostics {
    /// Handles bounded, read-only queries without requiring a synchronous
    /// native rendering loop to yield to Swift Concurrency's MainActor queue.
    /// Trace capture remains available through the asynchronous toolbox and
    /// the existing DevTools timeline stream, not this immediate-read adapter.
    func handleReadRequest(_ request: DevToolsEnvelope) -> DevToolsEnvelope {
        do {
            let payload: JSONValue
            switch request.type {
            case "diagnostics.tools":
                guard request.payload == nil || request.payload?.objectValue?.isEmpty == true else {
                    return .error(request, code: "bad_request", message: "diagnostics.tools takes no payload")
                }
                let definitions = UIDiagnosticTool.immediateReadTools
                    .map(\.definition)
                    .filter(\.readOnly)
                    .map(\.mcpDefinition)
                payload = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: ["tools": definitions]))
            case "diagnostics.call":
                guard let object = request.payload?.objectValue,
                      Set(object.keys).isSubset(of: ["name", "arguments"]),
                      let name = object["name"]?.stringValue, !name.isEmpty, name.utf8.count <= 128,
                      object["arguments"] == nil || object["arguments"]?.objectValue != nil else {
                    return .error(request, code: "bad_request", message: "diagnostics.call requires a tool name and an arguments object")
                }
                guard let tool = UIDiagnosticTools.tool(named: name), tool.isImmediateRead else {
                    return .error(request, code: "unsupported_tool", message: "Tool is not an immediate diagnostic read: \(name)")
                }
                let input = try JSONEncoder().encode(object["arguments"] ?? .object([:]))
                let result = try executeRead(tool: tool, input: input)
                payload = try JSONDecoder().decode(JSONValue.self, from: result.json)
            default:
                return .error(request, code: "unsupported", message: "Unsupported diagnostic request")
            }
            return DevToolsEnvelope(type: request.type + ".ok", id: request.id, payload: payload)
        } catch {
            return .error(request, code: "bad_request", message: error.localizedDescription)
        }
    }
}

private extension DevToolsEnvelope {
    static func error(_ request: Self, code: String, message: String) -> Self {
        DevToolsSession.error(request, code: code, message: message)
    }
}
