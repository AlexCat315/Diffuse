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

func toolResult(id: Any, text: String, isError: Bool = false) {
    writeResponse([
        "jsonrpc": "2.0",
        "id": id,
        "result": [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ] as [String: Any],
    ])
}

func errorResponse(id: Any, code: Int = -32603, message: String) {
    writeResponse([
        "jsonrpc": "2.0",
        "id": id,
        "error": ["code": code, "message": message] as [String: Any],
    ])
}

func handle(_ msg: [String: Any]) {
    let method = msg["method"] as? String ?? ""
    let id = msg["id"]
    let params = msg["params"] as? [String: Any] ?? [:]

    // Notifications — no response
    if msg["id"] == nil {
        return
    }

    switch method {
    case "initialize":
        let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
        let requestedVersion = params["protocolVersion"] as? String ?? ""
        writeResponse([
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "protocolVersion": supportedVersions.contains(requestedVersion) ? requestedVersion : supportedVersions[0],
                "capabilities": ["tools": ["listChanged": true] as [String: Any]] as [String: Any],
                "serverInfo": ["name": "guava", "version": "0.0.9"] as [String: Any],
            ] as [String: Any],
        ])

    case "ping":
        writeResponse(["jsonrpc": "2.0", "id": id as Any, "result": [:] as [String: Any]])

    case "tools/list":
        _ = openCapabilitySessionIfNeeded()
        let generatedTools = activeCapabilityTools.keys.sorted().compactMap { activeCapabilityTools[$0] }
        writeResponse([
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": ["tools": [toolSearchCapabilities, toolSubmitPlan] + ProjectToolset.tools.map(\.mcpDefinition) + generatedTools] as [String: Any],
        ])

    case "tools/call":
        guard let name = params["name"] as? String,
              params["arguments"] == nil || params["arguments"] is [String: Any] else {
            errorResponse(id: id as Any, code: -32602, message: "tools/call requires a tool name and object arguments")
            return
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case let projectTool where ProjectToolset.tools.contains(where: { $0.name == projectTool }):
            let response = editorCall(["action": "project_tool", "tool_name": projectTool, "arguments": args])
            toolResult(id: id as Any, text: jsonText(response), isError: response["ok"] as? Bool != true)

        case CapabilityToolset.searchToolName:
            var request = args
            request["action"] = "search_capabilities"
            request["session_id"] = capabilitySessionID
            let response = editorCall(request)
            installCapabilityTools(from: response)
            let failed = response["ok"] as? Bool != true
            toolResult(id: id as Any,
                       text: failed ? (response["error"] as? String ?? "capability search failed")
                                    : capabilitySearchText(response),
                       isError: failed)
            if !failed { writeNotification(method: "notifications/tools/list_changed") }

        case CapabilityToolset.submitToolName:
            var request = args
            request["action"] = "submit_capability_plan"
            request["session_id"] = capabilitySessionID
            let response = editorCall(request)
            let failed = response["ok"] as? Bool != true
            toolResult(id: id as Any,
                       text: failed ? (response["error"] as? String ?? "plan submission failed")
                                    : jsonText(response),
                       isError: failed)

        default:
            guard activeCapabilityTools[name] != nil else {
                errorResponse(id: id as Any, code: -32601, message: "unknown tool '\(name)'")
                break
            }
            let response = editorCall([
                "action": "invoke_capability",
                "session_id": capabilitySessionID,
                "tool_name": name,
                "arguments": args,
            ])
            let failed = response["ok"] as? Bool != true
            toolResult(id: id as Any,
                       text: failed ? (response["error"] as? String ?? "capability invocation failed")
                                    : jsonText(response),
                       isError: failed)
        }

    default:
        errorResponse(id: id as Any, code: -32601, message: "method not found: \(method)")
    }
}

// MARK: - Main loop

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard line.utf8.count <= 1_048_576 else {
        errorResponse(id: NSNull(), code: -32600, message: "request exceeds 1 MiB")
        continue
    }
    guard let data = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { errorResponse(id: NSNull(), code: -32700, message: "invalid JSON"); continue }
    guard msg["jsonrpc"] as? String == "2.0", msg["method"] is String else {
        errorResponse(id: msg["id"] ?? NSNull(), code: -32600, message: "invalid JSON-RPC request")
        continue
    }
    handle(msg)
}

if currentCapabilitySnapshotID != nil { _ = editorCall([
    "action": "close_capability_session",
    "session_id": capabilitySessionID,
]) }
