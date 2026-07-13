import Foundation
import AIRuntime
import CapabilityRuntime

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

// MARK: - IPC (TCP → Guava.app on localhost:9898)

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
    addr.sin_port = UInt16(9898).bigEndian
    // 127.0.0.1 (INADDR_LOOPBACK) in network byte order; avoids the
    // deprecated inet_addr() and its WSA-state dependency.
    addr.sin_addr.S_un.S_addr = UInt32(0x7f00_0001).bigEndian
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            WinSDK.connect(sock, $0, Int32(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        return ["ok": false, "error": "Guava is not running (could not connect to localhost:9898)"]
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

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(9898).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        return ["ok": false, "error": "Guava is not running (could not connect to localhost:9898)"]
    }

    let sent = payload.withUnsafeBytes { write(sock, $0.baseAddress, $0.count) }
    guard sent == payload.count else { return ["ok": false, "error": "write error"] }

    var responseData = Data()
    var byte = [UInt8](repeating: 0, count: 1)
    while read(sock, &byte, 1) == 1 {
        if byte[0] == UInt8(ascii: "\n") { break }
        responseData.append(byte[0])
    }
#endif

    guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
        return ["ok": false, "error": "invalid response from editor"]
    }
    return json
}

// MARK: - Tool definitions

let executeEditPlanContract = CapabilityContract(
    id: "system.execute_edit_plan_compatibility",
    title: "Execute edit plan",
    description: "Submit a structured Guava scene edit plan for host validation, preview, and user confirmation.",
    domain: "system",
    access: .reversibleWrite,
    releasePhase: .stable,
    inputSchema: EditPlanTool.jsonSchema()
)

let toolExecuteEditPlan: [String: Any] = [
    "name": "execute_edit_plan",
    "description": executeEditPlanContract.description,
    "inputSchema": executeEditPlanContract.inputSchema.jsonObject(),
]
let toolGetScene: [String: Any] = [
    "name": "get_scene_entities",
    "description": "Returns all entities in the open Guava scene with their IDs, names, positions, components, and properties.",
    "inputSchema": CapabilityRegistry.default.descriptor(for: "scene.get_entities")!.contract.inputSchema.jsonObject(),
]

let toolGetSelection: [String: Any] = [
    "name": "get_selection",
    "description": "Returns the entity ref of the currently selected object in the Guava editor, or null if nothing is selected.",
    "inputSchema": CapabilityRegistry.default.descriptor(for: "scene.get_selection")!.contract.inputSchema.jsonObject(),
]

let toolGetAIEntity: [String: Any] = [
    "name": "get_ai_entity",
    "description": "Returns Guava's AI-visible record for the selected or specified scene entity, including inferred semantic observations from local perception.",
    "inputSchema": [
        "type": "object",
        "properties": [
            "entity_id": ["type": "string",
                          "description": "Optional target entity ref such as 'scene:123'. Defaults to the current selection."] as [String: Any],
        ] as [String: Any],
    ] as [String: Any],
]

let toolSelectEntity: [String: Any] = [
    "name": "select_entity",
    "description": "Sets the active selection in the Guava editor to the specified entity. Pass null entity_id to clear the selection.",
    "inputSchema": [
        "type": "object",
        "properties": [
            "entity_id": ["type": "string",
                          "description": "Entity ref to select, e.g. 'scene:123'. Omit or pass null to clear selection."] as [String: Any],
        ] as [String: Any],
    ] as [String: Any],
]

let toolSetPlaybackState: [String: Any] = [
    "name": "set_playback_state",
    "description": "Controls the physics simulation playback state in the Guava editor. 'playing' starts the simulation (snapshots the scene first), 'paused' freezes it without losing state, 'stopped' stops and restores the original scene.",
    "inputSchema": [
        "type": "object",
        "required": ["state"],
        "properties": [
            "state": ["type": "string",
                      "enum": ["playing", "paused", "stopped"],
                      "description": "Target playback state."] as [String: Any],
        ] as [String: Any],
    ] as [String: Any],
]

let toolUndo: [String: Any] = [
    "name": "undo",
    "description": "Reverts the most recent scene edit in the Guava editor. Returns ok=true and applied=true when an undo was available, applied=false when the history is empty.",
    "inputSchema": [
        "type": "object",
        "properties": [:] as [String: Any],
    ] as [String: Any],
]

let toolRedo: [String: Any] = [
    "name": "redo",
    "description": "Re-applies the most recently undone scene edit in the Guava editor. Returns ok=true and applied=true when a redo was available, applied=false when the redo stack is empty.",
    "inputSchema": [
        "type": "object",
        "properties": [:] as [String: Any],
    ] as [String: Any],
]

let toolAnalyzeImage: [String: Any] = [
    "name": "analyze_image",
    "description": "Runs Guava Perception Runtime on a local image file and writes inferred semantic observations to the selected or specified scene entity. Uses the editor's local system perception worker.",
    "inputSchema": [
        "type": "object",
        "required": ["image_path"],
        "properties": [
            "image_path": ["type": "string",
                           "description": "Absolute path to a local image file readable by the editor."] as [String: Any],
            "entity_id": ["type": "string",
                          "description": "Optional target entity ref such as 'scene:123'. Defaults to the current selection."] as [String: Any],
            "task": ["type": "string",
                     "enum": ["classification", "object_detection", "image_embedding"],
                     "description": "Perception task to run. 'classification' labels what is in the image; 'object_detection' finds bounding boxes; 'image_embedding' stores a vector for similarity search. Defaults to 'classification'."] as [String: Any],
            "max_results": ["type": "integer",
                            "description": "Maximum observations to return. Defaults to 5."] as [String: Any],
        ] as [String: Any],
    ] as [String: Any],
]

let toolGetContextMemory: [String: Any] = [
    "name": "get_context_memory",
    "description": "Returns the top entries from Guava's long-term AI context memory for the current project. Entries include past edit summaries, scene annotations, user preferences, outstanding issues, and session summaries.",
    "inputSchema": [
        "type": "object",
        "properties": [
            "budget": ["type": "integer",
                       "description": "Maximum number of entries to return, ranked by importance. Defaults to 20."] as [String: Any],
        ] as [String: Any],
    ] as [String: Any],
]

let toolFindEntities: [String: Any] = [
    "name": "find_entities",
    "description": "Searches the scene for entities matching a name substring, kind, or both. Useful when the scene has many entities and you need to locate a specific one. Returns matching entity IDs, names, and kinds.",
    "inputSchema": CapabilityRegistry.default.descriptor(for: "scene.find_entities")!.contract.inputSchema.jsonObject(),
]

// MARK: - MCP stdio protocol

func writeResponse(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    var out = data
    out.append(UInt8(ascii: "\n"))
    FileHandle.standardOutput.write(out)
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
        writeResponse([
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]] as [String: Any],
                "serverInfo": ["name": "guava", "version": "0.0.1"] as [String: Any],
            ] as [String: Any],
        ])

    case "tools/list":
        writeResponse([
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": ["tools": [toolGetScene, toolGetSelection, toolSelectEntity, toolGetAIEntity, toolExecuteEditPlan, toolSetPlaybackState, toolAnalyzeImage, toolGetContextMemory, toolFindEntities, toolUndo, toolRedo]] as [String: Any],
        ])

    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "get_scene_entities":
            let res = editorCall(["action": "get_scene"])
            if let ok = res["ok"] as? Bool, ok,
               let sceneJSON = try? JSONSerialization.data(withJSONObject: res["scene"] as Any),
               let sceneText = String(data: sceneJSON, encoding: .utf8) {
                toolResult(id: id as Any, text: sceneText)
            } else {
                toolResult(id: id as Any, text: res["error"] as? String ?? "unknown error", isError: true)
            }

        case "get_selection":
            let res = editorCall(["action": "get_selection"])
            if let ok = res["ok"] as? Bool, ok {
                let ref = res["selectedRef"] as? String ?? "null"
                toolResult(id: id as Any, text: ref)
            } else {
                toolResult(id: id as Any, text: res["error"] as? String ?? "unknown error", isError: true)
            }

        case "select_entity":
            var request: [String: Any] = ["action": "select_entity"]
            if let entityID = args["entity_id"] as? String {
                request["entity_id"] = entityID
            }
            let selRes = editorCall(request)
            if let ok = selRes["ok"] as? Bool, ok {
                let ref = selRes["selectedRef"] as? String ?? "null"
                toolResult(id: id as Any, text: "Selected: \(ref)")
            } else {
                toolResult(id: id as Any, text: selRes["error"] as? String ?? "unknown error", isError: true)
            }

        case "get_ai_entity":
            var request: [String: Any] = ["action": "get_ai_entity"]
            if let entityID = args["entity_id"] as? String {
                request["entity_id"] = entityID
            }
            let res = editorCall(request)
            if let ok = res["ok"] as? Bool, ok,
               let responseData = try? JSONSerialization.data(withJSONObject: res, options: [.sortedKeys]),
               let responseText = String(data: responseData, encoding: .utf8) {
                toolResult(id: id as Any, text: responseText)
            } else {
                toolResult(id: id as Any, text: res["error"] as? String ?? "unknown error", isError: true)
            }

        case "execute_edit_plan":
            let res = editorCall(["action": "execute_plan", "plan": args])
            if let ok = res["ok"] as? Bool, ok {
                let summary = res["summary"] as? String ?? "Done"
                let disposition = res["disposition"] as? String ?? "confirmation_requested"
                toolResult(id: id as Any, text: "Submitted (\(disposition)): \(summary)")
            } else {
                toolResult(id: id as Any, text: res["error"] as? String ?? "unknown error", isError: true)
            }

        case "set_playback_state":
            let res = editorCall(["action": "set_playback_state", "state": args["state"] as Any])
            if let ok = res["ok"] as? Bool, ok {
                let state = res["state"] as? String ?? "unknown"
                toolResult(id: id as Any, text: "Playback state set to '\(state)'")
            } else {
                toolResult(id: id as Any, text: res["error"] as? String ?? "unknown error", isError: true)
            }

        case "analyze_image":
            guard let imagePath = args["image_path"] as? String else {
                toolResult(id: id as Any, text: "missing image_path", isError: true)
                break
            }
            var request: [String: Any] = ["action": "analyze_image", "image_path": imagePath]
            if let entityID = args["entity_id"] as? String { request["entity_id"] = entityID }
            if let task = args["task"] as? String { request["task"] = task }
            if let maxResults = args["max_results"] as? Int { request["max_results"] = maxResults }
            let res = editorCall(request)
            if let ok = res["ok"] as? Bool, ok,
               let responseData = try? JSONSerialization.data(withJSONObject: res, options: [.sortedKeys]),
               let responseText = String(data: responseData, encoding: .utf8) {
                toolResult(id: id as Any, text: responseText)
            } else {
                toolResult(id: id as Any, text: res["error"] as? String ?? "unknown error", isError: true)
            }

        case "get_context_memory":
            var request: [String: Any] = ["action": "get_context_memory"]
            if let budget = args["budget"] as? Int { request["budget"] = budget }
            let res = editorCall(request)
            if let ok = res["ok"] as? Bool, ok,
               let responseData = try? JSONSerialization.data(withJSONObject: res, options: [.sortedKeys]),
               let responseText = String(data: responseData, encoding: .utf8) {
                toolResult(id: id as Any, text: responseText)
            } else {
                toolResult(id: id as Any, text: res["error"] as? String ?? "unknown error", isError: true)
            }

        case "find_entities":
            var request: [String: Any] = ["action": "find_entities"]
            if let nameQuery = args["name"] as? String { request["name"] = nameQuery }
            if let kindFilter = args["kind"] as? String { request["kind"] = kindFilter }
            if let limit = args["limit"] as? Int { request["limit"] = limit }
            let res = editorCall(request)
            if let ok = res["ok"] as? Bool, ok,
               let responseData = try? JSONSerialization.data(withJSONObject: res, options: [.sortedKeys]),
               let responseText = String(data: responseData, encoding: .utf8) {
                toolResult(id: id as Any, text: responseText)
            } else {
                toolResult(id: id as Any, text: res["error"] as? String ?? "unknown error", isError: true)
            }

        case "undo":
            let res = editorCall(["action": "undo"])
            let applied = res["applied"] as? Bool ?? false
            toolResult(id: id as Any, text: applied ? "Undo applied." : "Nothing to undo.")

        case "redo":
            let res = editorCall(["action": "redo"])
            let applied = res["applied"] as? Bool ?? false
            toolResult(id: id as Any, text: applied ? "Redo applied." : "Nothing to redo.")

        default:
            errorResponse(id: id as Any, code: -32601, message: "unknown tool '\(name)'")
        }

    default:
        errorResponse(id: id as Any, code: -32601, message: "method not found: \(method)")
    }
}

// MARK: - Main loop

while let line = readLine(strippingNewline: true), !line.isEmpty {
    guard let data = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }
    handle(msg)
}
