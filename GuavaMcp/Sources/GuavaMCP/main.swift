import Foundation
import AIRuntime
import CapabilityRuntime
import IntentRuntime

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

// MARK: - IPC (TCP → Guava.app on localhost:\(editorPort))

func editorCall(_ request: [String: Any]) -> [String: Any] {
    guard var payload = try? JSONSerialization.data(withJSONObject: request) else {
        return ["ok": false, "error": "serialization error"]
    }
    payload.append(UInt8(ascii: "\n"))

#if os(Windows)
    var wsaData = WSADATA()
    // MAKEWORD(2, 2): function-like C macros are not imported into Swift,
    // so compute the requested Winsock version (2.2) directly.
    let wsaVersion = WORD(2) | (WORD(2) << 8)
    guard WSAStartup(wsaVersion, &wsaData) == 0 else {
        return ["ok": false, "error": "WSAStartup failed"]
    }
    defer { WSACleanup() }

    let sock = WinSDK.socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP.rawValue))
    guard sock != INVALID_SOCKET else { return ["ok": false, "error": "socket() failed"] }
    defer { closesocket(sock) }

    var addr = sockaddr_in()
    addr.sin_family = ADDRESS_FAMILY(AF_INET)
    addr.sin_port = editorPort.bigEndian
    // 127.0.0.1 (INADDR_LOOPBACK) in network byte order; avoids the
    // deprecated inet_addr() and its WSA-state dependency.
    addr.sin_addr.S_un.S_addr = UInt32(0x7f00_0001).bigEndian
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            WinSDK.connect(sock, $0, Int32(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        return ["ok": false, "error": "Guava is not running (could not connect to localhost:\(editorPort))"]
    }

    let sent = payload.withUnsafeBytes {
        send(sock, $0.baseAddress!.assumingMemoryBound(to: CChar.self), Int32($0.count), 0)
    }
    guard sent == Int32(payload.count) else { return ["ok": false, "error": "write error"] }

    var responseData = Data()
    var byte: CChar = 0
    while recv(sock, &byte, 1, 0) == 1 {
        if byte == CChar(bitPattern: UInt8(ascii: "\n")) { break }
        responseData.append(UInt8(bitPattern: byte))
    }
#else
#if canImport(Glibc)
    let sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
#else
    let sock = socket(AF_INET, SOCK_STREAM, 0)
#endif
    guard sock >= 0 else { return ["ok": false, "error": "socket() failed"] }
    defer { close(sock) }

    var timeout = timeval(tv_sec: 180, tv_usec: 0)
    _ = withUnsafePointer(to: &timeout) { setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
    _ = withUnsafePointer(to: &timeout) { setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
    #if canImport(Darwin)
    var noSignal: Int32 = 1
    _ = withUnsafePointer(to: &noSignal) { setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size)) }
    #endif

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(editorPort).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        return ["ok": false, "error": "Guava is not running (could not connect to localhost:\(editorPort))"]
    }

    var sent = 0
    while sent < payload.count {
        let count = payload.withUnsafeBytes { bytes in
            #if canImport(Glibc)
            return send(sock, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, Int32(MSG_NOSIGNAL))
            #else
            return write(sock, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
            #endif
        }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { return ["ok": false, "error": "editor connection write failed"] }
        sent += count
    }

    var responseData = Data()
    var bytes = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = read(sock, &bytes, bytes.count)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { return ["ok": false, "error": "editor disconnected or response timed out"] }
        responseData.append(contentsOf: bytes.prefix(count))
        guard responseData.count <= 2_097_152 else { return ["ok": false, "error": "editor response exceeds 2 MiB"] }
        if let newline = responseData.firstIndex(of: 10) {
            responseData = Data(responseData[..<newline])
            break
        }
    }
#endif

    guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
        return ["ok": false, "error": "invalid response from editor"]
    }
    return json
}

// MARK: - Tool definitions

let registry = CapabilityRegistry.aiDefault
let editorPort = ProcessInfo.processInfo.environment["GUAVA_MCP_PORT"].flatMap(UInt16.init) ?? 9898
let capabilitySessionID = UUID().uuidString
var activeCapabilityTools: [String: [String: Any]] = [:]
var currentCapabilitySnapshotID: String?

func frameworkTool(capabilityID: String, name: String) -> [String: Any] {
    guard let contract = registry.descriptor(for: capabilityID)?.contract else {
        return ["name": name,
                "description": "Unavailable Guava framework capability",
                "inputSchema": ["type": "object", "properties": [:]]]
    }
    return [
        "name": name,
        "description": contract.description,
        "inputSchema": contract.inputSchema.jsonObject(),
    ]
}

let toolSearchCapabilities = frameworkTool(capabilityID: "system.search_capabilities",
                                           name: CapabilityToolset.searchToolName)
let toolSubmitPlan = frameworkTool(capabilityID: "system.submit_plan",
                                   name: CapabilityToolset.submitToolName)
let toolReloadPlugin: [String: Any] = [
    "name": "reload_plugin",
    "description": "Re-mount an enabled plugin whose package (code, WIT, permissions, schemas, requirements) still matches its stored authorization. Changed packages are rejected until the user re-authorizes them in the Editor; this never authorizes on its own.",
    "inputSchema": [
        "type": "object",
        "properties": [
            "plugin_id": ["type": "string", "minLength": 1],
        ],
        "required": ["plugin_id"],
        "additionalProperties": false,
    ],
]

func installCapabilityTools(from response: [String: Any]) {
    guard response["ok"] as? Bool == true else { return }
    if let snapshotID = response["snapshot_id"] as? String,
       snapshotID != currentCapabilitySnapshotID {
        activeCapabilityTools.removeAll()
        currentCapabilitySnapshotID = snapshotID
    }
    guard let capabilities = (response["active_capabilities"] as? [[String: Any]])
        ?? (response["capabilities"] as? [[String: Any]]) else { return }
    for capability in capabilities {
        guard let name = capability["tool_name"] as? String,
              let description = capability["description"] as? String,
              let schema = capability["input_schema"] as? [String: Any] else { continue }
        activeCapabilityTools[name] = [
            "name": name,
            "description": description,
            "inputSchema": schema,
        ]
    }
}

@discardableResult
func openCapabilitySessionIfNeeded() -> [String: Any] {
    if !activeCapabilityTools.isEmpty { return ["ok": true] }
    let response = editorCall([
        "action": "open_capability_session",
        "session_id": capabilitySessionID,
    ])
    installCapabilityTools(from: response)
    return response
}

// MARK: - MCP stdio protocol

func writeResponse(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    var out = data
    out.append(UInt8(ascii: "\n"))
    FileHandle.standardOutput.write(out)
}

func writeNotification(method: String) {
    writeResponse(["jsonrpc": "2.0", "method": method])
}

func jsonText(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}

func capabilitySearchText(_ response: [String: Any]) -> String {
    var publicResponse = response
    publicResponse.removeValue(forKey: "active_capabilities")
    if let capabilities = response["capabilities"] as? [[String: Any]] {
        publicResponse["capabilities"] = capabilities.map { capability in
            var metadata = capability
            metadata.removeValue(forKey: "input_schema")
            return metadata
        }
    }
    return jsonText(publicResponse)
}

func toolDescriptors() throws -> [AgentTool] {
    _ = openCapabilitySessionIfNeeded()
    let definitions = [toolSearchCapabilities, toolSubmitPlan, toolReloadPlugin]
        + activeCapabilityTools.keys.sorted().compactMap { activeCapabilityTools[$0] }
    let capabilities = try definitions.map { definition -> AgentTool in
        let schema = try JSONDecoder().decode(JSONSchema.self,
            from: JSONSerialization.data(withJSONObject: definition["inputSchema"] ?? [:]))
        return AgentTool(name: definition["name"] as? String ?? "",
            description: definition["description"] as? String ?? "", schema: schema,
            readOnly: (definition["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool ?? false)
    }
    return ProjectToolset.tools + capabilities
}

func invokeTool(_ name: String, input: Data) throws -> AgentToolResult {
    let args = try JSONSerialization.jsonObject(with: input) as? [String: Any] ?? [:]
    let response: [String: Any]
    switch name {
    case let projectTool where ProjectToolset.tools.contains(where: { $0.name == projectTool }):
        response = editorCall(["action": "project_tool", "tool_name": projectTool, "arguments": args])
    case CapabilityToolset.searchToolName:
        var request = args
        request["action"] = "search_capabilities"
        request["session_id"] = capabilitySessionID
        let found = editorCall(request)
        installCapabilityTools(from: found)
        if found["ok"] as? Bool == true { writeNotification(method: "notifications/tools/list_changed") }
        // Discovery metadata is bounded by the host; generated tool schemas are
        // returned through tools/list rather than repeated in this result.
        response = (try? JSONSerialization.jsonObject(with: Data(capabilitySearchText(found).utf8)) as? [String: Any]) ?? found
    case CapabilityToolset.submitToolName:
        var request = args
        request["action"] = "submit_capability_plan"
        request["session_id"] = capabilitySessionID
        response = editorCall(request)
    case "reload_plugin":
        var request = args
        request["action"] = "reload_plugin"
        response = editorCall(request)
    default:
        guard activeCapabilityTools[name] != nil else { throw AgentError.unknownTool(name) }
        response = editorCall(["action": "invoke_capability", "session_id": capabilitySessionID,
                               "tool_name": name, "arguments": args])
    }
    return AgentToolResult(json: try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
                           isError: response["ok"] as? Bool != true)
}

let mcp = MCPServer(name: "guava", version: "0.0.9", skills: try UIDiagnosticTools.skills(),
    tools: { try toolDescriptors() }, execute: { try invokeTool($0, input: $1) })

// MARK: - Main loop

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    if let response = await mcp.respond(to: Data(line.utf8)) {
        FileHandle.standardOutput.write(response)
        FileHandle.standardOutput.write(Data([10]))
    }
}

if currentCapabilitySnapshotID != nil { _ = editorCall([
    "action": "close_capability_session",
    "session_id": capabilitySessionID,
]) }
