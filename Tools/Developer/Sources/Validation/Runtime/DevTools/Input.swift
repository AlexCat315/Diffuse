internal import Foundation
internal import ToolSupport

/// Port of `scripts/input-ui-devtools.swift`: drive the host's input dispatcher
/// through DevTools, without OS automation.
enum InputUI {
  static let usage = "guava-dev devtools input-ui PORT|@SESSION_FILE --click-node NODE_ID | --input JSON_OR_@FILE [--capture OUTPUT.jpg] (events may include {\"kind\":\"wait\",\"milliseconds\":100}; --capture mirrors the window right after delivery, for transient states)"

  static func run(_ arguments: [String]) throws {
    if arguments.contains("-h") || arguments.contains("--help") {
      Terminal.info(usage)
      return
    }
    guard arguments.count == 3 || (arguments.count == 5 && arguments[3] == "--capture"),
      ["--click-node", "--input"].contains(arguments[1])
    else {
      throw ToolError.message("Usage: \(usage)")
    }
    let capture = arguments.count == 5 ? URL(fileURLWithPath: arguments[4]) : nil
    let endpoint = try DevToolsEndpoint.resolve(arguments[0])
    let target = arguments[1]
    let raw = arguments[2]

    #if !canImport(Darwin)
      throw ToolError.message("DevTools input requires macOS")
    #else
      try AsyncBridge.wait {
        let connection = DevToolsSocket(
          url: endpoint, timeout: 30, maximumMessageSize: 32 * 1024 * 1024)
        defer { connection.close() }

        var sequence = 0
        func request(_ type: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
          sequence += 1
          let identifier = sequence
          try await connection.send(["type": type, "id": identifier, "payload": payload])
          while true {
            let response = try await connection.receive()
            guard response["id"] as? Int == identifier else { continue }
            guard response["type"] as? String == type + ".ok" else {
              throw ToolError.message(JSON.text(response["payload"] ?? [:]))
            }
            return response["payload"] as? [String: Any] ?? [:]
          }
        }

        let hello = try await connection.receive()
        let capabilities = (hello["payload"] as? [String: Any])?["capabilities"] as? [String] ?? []
        guard hello["type"] as? String == "hello", capabilities.contains("mirror"),
          capabilities.contains("diagnostics")
        else {
          throw ToolError.message("Host must advertise mirror and diagnostics")
        }

        let events: [[String: Any]]
        if target == "--click-node" {
          events = try await clickEvents(node: raw, request: request)
        } else {
          events = try loadEvents(raw)
        }

        _ = try await request("mirror.start", ["fps": 1, "quality": 0.5])
        for event in events {
          if event["kind"] as? String == "wait", let delay = event["milliseconds"] as? Double {
            // Keep the same connection and pointer capture while the host
            // composes, lays out and renders intermediate gesture frames.
            try await Task.sleep(for: .milliseconds(delay))
          } else {
            _ = try await request("mirror.input", event)
          }
        }
        // A host-inbox read keeps the connection alive until the preceding
        // input deliveries have reached the host.
        _ = try await request(
          "diagnostics.call", ["name": "get_diagnostics", "arguments": ["limit": 1]])
        _ = try await request("mirror.stop")
        Terminal.info(
          "Delivered \(events.count) input events through DevTools; query or capture the resulting UI to verify behavior."
        )
      }
      // A second connection is opened at once, so transient states such as a
      // fading indicator or a mid-flight transition are still on screen.
      if let capture { try CaptureUI.capture(endpoint: endpoint, destination: capture) }
    #endif
  }

  /// Pointer events centred on the node's visible, input-enabled hit region.
  private static func clickEvents(
    node: String,
    request: (String, [String: Any]) async throws -> [String: Any]
  ) async throws -> [[String: Any]] {
    let result = try await request(
      "diagnostics.call",
      [
        "name": "query_ui_nodes",
        "arguments": [
          "node_id": node, "visible_only": true, "input_enabled_only": true, "limit": 1,
        ],
      ])
    guard let items = (result["data"] as? [String: Any])?["items"] as? [[String: Any]],
      items.count == 1,
      let presentation = items[0]["presentation"] as? [String: Any],
      let frame = presentation["visibleFrame"] as? [String: Double],
      let x = frame["x"], let y = frame["y"], let width = frame["w"], let height = frame["h"],
      [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0
    else {
      throw ToolError.message(
        "Node has no visible input-enabled hit region; query the current window again")
    }
    return ["pointerMove", "pointerDown", "pointerUp"].map {
      ["kind": $0, "x": x + width / 2, "y": y + height / 2, "button": 0, "clickCount": 1]
    }
  }

  /// Validates an inline or `@FILE` array of 1–256 input events.
  static func loadEvents(_ raw: String) throws -> [[String: Any]] {
    let bytes =
      try raw.hasPrefix("@")
      ? Fs.read(URL(fileURLWithPath: String(raw.dropFirst())))
      : Data(raw.utf8)
    guard bytes.count <= 262_144,
      let input = (try? JSON.parse(bytes)) as? [[String: Any]], (1...256).contains(input.count)
    else {
      throw ToolError.message("Input must be a JSON array of 1–256 events, at most 256 KiB")
    }
    let kinds = ["pointerMove", "pointerDown", "pointerUp", "wheel", "keyDown", "keyUp", "text", "wait"]
    func supported(_ value: Any, depth: Int = 0) -> Bool {
      if depth > 4 { return false }
      if let number = value as? NSNumber { return number.doubleValue.isFinite }
      if let text = value as? String { return text.utf8.count <= 16_384 }
      if let dictionary = value as? [String: Any] {
        return dictionary.values.allSatisfy { supported($0, depth: depth + 1) }
      }
      if let array = value as? [Any] {
        return array.count <= 64 && array.allSatisfy { supported($0, depth: depth + 1) }
      }
      return false
    }
    var totalWait = 0.0
    guard
      input.allSatisfy({ event in
        guard let kind = event["kind"] as? String, kinds.contains(kind) else { return false }
        if kind == "wait" {
          guard event.count == 2, let delay = event["milliseconds"] as? Double,
            delay.isFinite, delay > 0, delay <= 2_000 else { return false }
          totalWait += delay
        }
        return event.values.allSatisfy { supported($0) }
      }), totalWait <= 10_000
    else {
      throw ToolError.message("Input contains an unsupported kind, value or oversized string")
    }
    return try input.map { try normalizeModifiers(normalizeKeyEvent(normalizePointerEvent($0))) }
  }

  private static func normalizePointerEvent(_ event: [String: Any]) throws -> [String: Any] {
    guard let kind = event["kind"] as? String, kind.hasPrefix("pointer"), let button = event["button"] else { return event }
    var result = event
    if let name = button as? String, let code = ["left": 0, "middle": 1, "right": 2, "back": 3, "forward": 4][name.lowercased()] {
      result["button"] = code
    } else if let number = button as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), (0...4).contains(number.intValue),
              number.doubleValue == Double(number.intValue) {
      result["button"] = number.intValue
    } else {
      throw ToolError.message("Pointer button must be left, middle, right, back, forward or an integer from 0 to 4")
    }
    return result
  }

  private static func normalizeKeyEvent(_ event: [String: Any]) throws -> [String: Any] {
    guard let kind = event["kind"] as? String, kind == "keyDown" || kind == "keyUp" else { return event }
    var result = event
    if result["key"] == nil, let scancode = result["scancode"] as? NSNumber {
      result["key"] = keyName(for: scancode.intValue)
    }
    guard let key = result["key"] as? String, (4...99).contains(where: { keyName(for: $0) == key }) else {
      throw ToolError.message("Keyboard input requires a supported KeyboardEvent.code (for example KeyA, Enter or ArrowUp) or USB-HID scancode")
    }
    return result
  }

  /// Pointer and key events accept modifier names (shift, ctrl, alt, cmd);
  /// unknown names fail instead of silently sending an unmodified event.
  private static func normalizeModifiers(_ event: [String: Any]) throws -> [String: Any] {
    guard let modifiers = event["modifiers"] as? [String] else { return event }
    var result = event, mask = 0
    for modifier in modifiers.map({ $0.lowercased() }) {
      switch modifier {
      case "shift": mask |= 1
      case "ctrl", "control": mask |= 2
      case "alt", "option": mask |= 4
      case "gui", "cmd", "command", "meta": mask |= 8
      default: throw ToolError.message("Unknown modifier '\(modifier)'; use shift, ctrl, alt or cmd")
      }
    }
    result["modifiers"] = mask
    return result
  }

  private static func keyName(for scancode: Int) -> String? {
    switch scancode {
    case 4...29: return "Key" + String(UnicodeScalar(65 + scancode - 4)!)
    case 30...38: return "Digit\(scancode - 29)"
    case 39: return "Digit0"
    case 58...69: return "F\(scancode - 57)"
    case 89...97: return "Numpad\(scancode - 88)"
    case 98: return "Numpad0"
    case 40: return "Enter"
    case 88: return "NumpadEnter"
    case 41: return "Escape"
    case 42: return "Backspace"
    case 43: return "Tab"
    case 44: return "Space"
    case 74: return "Home"
    case 77: return "End"
    case 75: return "PageUp"
    case 78: return "PageDown"
    case 79: return "ArrowRight"
    case 80: return "ArrowLeft"
    case 81: return "ArrowDown"
    case 82: return "ArrowUp"
    case 45: return "Minus"
    case 46: return "Equal"
    case 47: return "BracketLeft"
    case 48: return "BracketRight"
    case 49: return "Backslash"
    case 51: return "Semicolon"
    case 52: return "Quote"
    case 53: return "Backquote"
    case 54: return "Comma"
    case 55: return "Period"
    case 56: return "Slash"
    case 57: return "CapsLock"
    case 70: return "PrintScreen"
    case 71: return "ScrollLock"
    case 72: return "Pause"
    case 73: return "Insert"
    case 76: return "Delete"
    case 83: return "NumLock"
    case 84: return "NumpadDivide"
    case 85: return "NumpadMultiply"
    case 86: return "NumpadSubtract"
    case 87: return "NumpadAdd"
    case 99: return "NumpadDecimal"
    default: return nil
    }
  }
}
