import Foundation

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
    guard WSAStartup(MAKEWORD(2, 2), &wsaData) == 0 else {
        return ["ok": false, "error": "WSAStartup failed"]
    }
    defer { WSACleanup() }

    let sock = WinSDK.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard sock != INVALID_SOCKET else { return ["ok": false, "error": "socket() failed"] }
    defer { closesocket(sock) }

    var addr = sockaddr_in()
    addr.sin_family = ADDRESS_FAMILY(AF_INET)
    addr.sin_port = UInt16(9898).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
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
    let sock = socket(AF_INET, SOCK_STREAM, 0)
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

let toolExecuteEditPlan: [String: Any] = [
    "name": "execute_edit_plan",
    "description": "Apply a structured edit plan to the Guava scene. Entities use 'scene:<number>' IDs — use get_scene_entities first to discover them.",
    "inputSchema": [
        "type": "object",
        "required": ["summary", "steps"],
        "properties": [
            "summary": ["type": "string", "description": "One-line description of what the plan achieves."] as [String: Any],
            "reasoning": ["type": "string", "description": "Brief reasoning for debugging."] as [String: Any],
            "steps": [
                "type": "array",
                "description": "Ordered list of atomic mutation steps.",
                "items": [
                    "type": "object",
                    "required": ["op"],
                    "properties": [
                        "op": ["type": "string",
                               "enum": ["spawn_entity","delete_entity","duplicate_entity","set_name",
                                        "reparent_entity","set_transform","snap_to_ground",
                                        "set_mesh_color","set_material",
                                        "set_light_type","set_light_intensity","set_light_color",
                                        "set_light_range","set_light_spot_angles",
                                        "set_light_cast_shadows",
                                        "set_camera_pose","set_camera_fov","set_camera_active",
                                        "set_rigidbody_motion","set_rigidbody_mass","set_rigidbody_gravity",
                                        "set_rigidbody_allow_sleep",
                                        "set_collider_trigger","set_collider_layer","set_constraint_enabled",
                                        "set_collider_shape",
                                        "set_collider_box_extents","set_collider_sphere_radius","set_collider_capsule",
                                        "set_collider_material",
                                        "set_audio_source",
                                        "set_script_property",
                                        "set_mesh_visibility",
                                        "set_animation_player"],
                               "description": "The mutation op to perform."] as [String: Any],
                        "entity_id": ["type": "string", "description": "Target entity 'scene:<number>'. Required for all ops except spawn_entity."] as [String: Any],
                        "parent_id": ["type": "string", "description": "New parent 'scene:<number>' for reparent_entity. Omit for root."] as [String: Any],
                        "label": ["type": "string"] as [String: Any],
                        "spawn_position": ["type": "array", "items": ["type": "number"] as [String: Any]] as [String: Any],
                        "position": ["type": "array", "items": ["type": "number"] as [String: Any], "description": "[x,y,z] metres"] as [String: Any],
                        "euler_degrees": ["type": "array", "items": ["type": "number"] as [String: Any]] as [String: Any],
                        "scale": ["type": "array", "items": ["type": "number"] as [String: Any]] as [String: Any],
                        "name": ["type": "string"] as [String: Any],
                        "color": ["type": "array", "items": ["type": "number"] as [String: Any], "description": "[r,g,b] linear 0-1. red=[1,0,0] green=[0,1,0] blue=[0,0,1]"] as [String: Any],
                        "light_type": ["type": "string", "enum": ["directional","point","spot"]] as [String: Any],
                        "intensity": ["type": "number"] as [String: Any],
                        "range": ["type": "number"] as [String: Any],
                        "spot_inner_angle": ["type": "number"] as [String: Any],
                        "spot_outer_angle": ["type": "number"] as [String: Any],
                        "light_cast_shadows": ["type": "boolean", "description": "Whether the light casts shadows for set_light_cast_shadows."] as [String: Any],
                        "camera_fov_y": ["type": "number", "description": "Vertical FOV in degrees (1–179) for set_camera_fov. 30=telephoto 50=normal 75=wide."] as [String: Any],
                        "camera_is_active": ["type": "boolean", "description": "Whether this camera is the active render camera for set_camera_active."] as [String: Any],
                        "motion_type": ["type": "string", "enum": ["static","dynamic","kinematic"]] as [String: Any],
                        "mass": ["type": "number"] as [String: Any],
                        "gravity_scale": ["type": "number"] as [String: Any],
                        "allow_sleep": ["type": "boolean", "description": "Whether the rigidbody can go to sleep when at rest."] as [String: Any],
                        "collider_shape": ["type": "string", "enum": ["box","sphere","capsule","mesh","convex"],
                                           "description": "Shape kind for set_collider_shape."] as [String: Any],
                        "half_extents": ["type": "array", "items": ["type": "number"] as [String: Any],
                                         "description": "[x,y,z] box half-sizes for set_collider_box_extents."] as [String: Any],
                        "radius": ["type": "number", "description": "Sphere/capsule radius for set_collider_sphere_radius or set_collider_capsule."] as [String: Any],
                        "half_height": ["type": "number", "description": "Capsule half-height for set_collider_capsule."] as [String: Any],
                        "friction": ["type": "number", "description": "Collider surface friction (0–1) for set_collider_material."] as [String: Any],
                        "restitution": ["type": "number", "description": "Collider bounciness (0–1) for set_collider_material."] as [String: Any],
                        "density": ["type": "number", "description": "Collider material density for set_collider_material."] as [String: Any],
                        "is_trigger": ["type": "boolean"] as [String: Any],
                        "is_enabled": ["type": "boolean"] as [String: Any],
                        "collider_layer_id": ["type": "integer", "description": "Physics layer the collider occupies (0–15) for set_collider_layer."] as [String: Any],
                        "collider_layer_mask": ["type": "integer", "description": "Bitmask of layers this collider interacts with (e.g. 65535=all) for set_collider_layer."] as [String: Any],
                        "audio_clip": ["type": "string", "description": "Audio clip asset name (no extension) for set_audio_source."] as [String: Any],
                        "audio_volume": ["type": "number", "description": "Playback volume 0–1 for set_audio_source."] as [String: Any],
                        "audio_pitch": ["type": "number", "description": "Pitch multiplier (1=normal) for set_audio_source."] as [String: Any],
                        "audio_loop": ["type": "boolean", "description": "Whether the clip loops for set_audio_source."] as [String: Any],
                        "audio_play_on_awake": ["type": "boolean", "description": "Auto-play when simulation starts for set_audio_source."] as [String: Any],
                        "audio_spatial_blend": ["type": "number", "description": "0=2D, 1=3D positional for set_audio_source."] as [String: Any],
                        "script_index": ["type": "integer", "description": "Zero-based index of the script component on the entity for set_script_property."] as [String: Any],
                        "script_property_name": ["type": "string", "description": "Exported property name to set for set_script_property."] as [String: Any],
                        "script_property_value": ["description": "Value to set (string, number, or boolean) for set_script_property."] as [String: Any],
                        "is_visible": ["type": "boolean", "description": "Mesh visibility toggle for set_mesh_visibility."] as [String: Any],
                        "material_base_color": ["type": "array", "items": ["type": "number"] as [String: Any],
                                                "description": "[r,g,b,a] linear 0-1 base colour for set_material. Omit to leave unchanged."] as [String: Any],
                        "material_metallic": ["type": "number", "description": "Metallic factor 0–1 for set_material. Omit to leave unchanged."] as [String: Any],
                        "material_roughness": ["type": "number", "description": "Roughness factor 0–1 for set_material. Omit to leave unchanged."] as [String: Any],
                        "material_emissive": ["type": "array", "items": ["type": "number"] as [String: Any],
                                              "description": "[r,g,b] linear 0-1 emission colour for set_material. Omit for no emission."] as [String: Any],
                        "animation_clip": ["type": "string", "description": "Animation clip asset name for set_animation_player."] as [String: Any],
                        "animation_speed": ["type": "number", "description": "Playback speed multiplier (1=normal) for set_animation_player."] as [String: Any],
                        "animation_loop": ["type": "boolean", "description": "Whether the animation loops for set_animation_player."] as [String: Any],
                        "animation_is_playing": ["type": "boolean", "description": "Whether to start/stop playback for set_animation_player."] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
    ] as [String: Any],
]

let toolGetScene: [String: Any] = [
    "name": "get_scene_entities",
    "description": "Returns all entities in the open Guava scene with their IDs, names, positions, components, and properties.",
    "inputSchema": ["type": "object", "properties": [:] as [String: Any]] as [String: Any],
]

let toolGetSelection: [String: Any] = [
    "name": "get_selection",
    "description": "Returns the entity ref of the currently selected object in the Guava editor, or null if nothing is selected.",
    "inputSchema": ["type": "object", "properties": [:] as [String: Any]] as [String: Any],
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
            "max_results": ["type": "integer",
                            "description": "Maximum classification observations to return. Defaults to 5."] as [String: Any],
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
            "result": ["tools": [toolGetScene, toolGetSelection, toolSelectEntity, toolGetAIEntity, toolExecuteEditPlan, toolSetPlaybackState, toolAnalyzeImage, toolGetContextMemory, toolUndo, toolRedo]] as [String: Any],
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
                toolResult(id: id as Any, text: "Applied: \(summary)")
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
            if let entityID = args["entity_id"] as? String {
                request["entity_id"] = entityID
            }
            if let maxResults = args["max_results"] as? Int {
                request["max_results"] = maxResults
            }
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
