internal import Foundation
internal import ToolSupport

/// Port of `scripts/android/verify-gallery.py`: renders every repository Gallery
/// page on Android and checks real pixels and semantics.
enum GalleryOperation {
  private static let package = "com.guava.probe"

  static func run(_ arguments: [String]) throws {
    let parsed = try ParsedArguments.parse(
      arguments,
      options: [
        OptionDefinition("--serial", arity: 1),
        OptionDefinition("--android-sdk", arity: 1),
        OptionDefinition("--pages", arity: -1),
        OptionDefinition("--interactions-only", arity: 0),
      ], positionals: 0)
    let adb = try AndroidTools.adbDevice(
      AndroidTools.sdkRoot(parsed.value("--android-sdk")), parsed.value("--serial"))
    let directory = try AndroidTools.makeRunDirectory("gallery-run-")

    let catalog = try catalog()
    if let requested = parsed.list("--pages") {
      let unknown = Set(requested).subtracting(catalog)
      guard unknown.isEmpty else {
        throw ToolError.message(
          "Unknown Gallery pages: " + unknown.sorted().joined(separator: ", "))
      }
    }
    let interactionsOnly = parsed.isPresent("--interactions-only")
    let pages = interactionsOnly ? [] : (parsed.list("--pages") ?? catalog)
    var checks: [JSON] = []

    func shell(_ values: [any CustomStringConvertible]) throws -> String {
      try Command.output(adb + ["shell", AndroidTools.shellCommand(values)])
    }

    func read() throws -> JSON {
      try JSON.parse(
        try Command.output(adb + ["exec-out", "run-as", package, "cat", "files/demo-state.json"]))
    }

    func wait(_ predicate: (JSON) -> Bool) throws -> JSON {
      let deadline = AndroidTools.uptime + 20
      var last: JSON = .null
      while AndroidTools.uptime < deadline {
        do {
          last = try read()
          if predicate(last) { return last }
        } catch {}
        Thread.sleep(forTimeInterval: 0.15)
      }
      let failure = directory.appendingPathComponent("failure.json")
      try Fs.write(last.prettyPrinted(), to: failure)
      throw ToolError.message("Gallery did not reach requested state; snapshot: \(failure.path)")
    }

    func launch(_ page: String) throws -> JSON {
      var previous: JSON = .null
      do { previous = try read()["session"] } catch { previous = .null }
      _ = try shell([
        "am", "start", "-W", "-n", "com.guava.probe/.MainActivity", "--es", "mode", "gallery",
        "--es", "component", page, "--ei", "orientation", 0, "--ez", "snapshots", "true",
      ])
      return try wait { snapshot in
        snapshot["mode"] == .string("gallery") && snapshot["page"] == .string(page)
          && snapshot["session"] != previous
      }
    }

    func tap(_ snapshot: JSON, _ node: JSON) throws {
      let bounds = node["bounds"]
      let scale = snapshot["scale"].doubleValue ?? 0
      let surface = snapshot["surface"]
      let x =
        (surface["x"].doubleValue ?? 0)
        + ((bounds["x"].doubleValue ?? 0) + (bounds["width"].doubleValue ?? 0) / 2) * scale
      let y =
        (surface["y"].doubleValue ?? 0)
        + ((bounds["y"].doubleValue ?? 0) + (bounds["height"].doubleValue ?? 0) / 2) * scale
      _ = try shell(["input", "tap", pythonRound(x), pythonRound(y)])
    }

    /// Saves the real screenshot, rejects a blank Swift surface, and returns
    /// the SHA-256 of the raw PNG bytes.
    func screenshot(_ page: String) throws -> String {
      let data = try Command.data(adb + ["exec-out", "screencap", "-p"])
      let path = directory.appendingPathComponent(page + ".png")
      try Fs.write(data, to: path)
      let image = try Bitmap.load(path)
      let bounds = try read()["surface"]
      let crop = image.cropped(
        bounds["x"].roundedInt, bounds["y"].roundedInt,
        bounds["x"].roundedInt + bounds["width"].roundedInt,
        bounds["y"].roundedInt + bounds["height"].roundedInt)
      guard crop.maxChannelStdDev > 12 else {
        throw ToolError.message("\(page): blank Swift surface")
      }
      return SHA256.hex(data)
    }

    // MARK: Every catalog page

    for page in pages {
      let snapshot = try launch(page)
      guard (snapshot["indices"].intValue ?? 0) > 1000, snapshot["nodes"].elements.count > 10 else {
        throw ToolError.message(page)
      }
      checks.append(
        .object([
          ("page", .string(page)), ("pixels", .string(try screenshot(page))),
          ("snapshot", snapshot),
        ]))
      Terminal.info("PASS page \(page)")
    }

    // MARK: Interactions

    if parsed.list("--pages") == nil || interactionsOnly {
      var snapshot = try launch("checkbox")
      guard
        let target = snapshot["nodes"].elements.first(where: {
          $0["role"] == .string("checkbox") && $0["enabled"].boolValue == true
            && ($0["bounds"]["y"].doubleValue ?? 0) > 180
        })
      else {
        throw ToolError.message("checkbox: no enabled checkbox below the header")
      }
      try tap(snapshot, target)
      let changed = try wait { state in
        state["nodes"].elements.contains {
          $0["id"] == target["id"] && $0["selected"] != target["selected"]
        }
      }
      checks.append(
        .object([
          ("check", .string("checkbox touch updates controlled state")), ("snapshot", changed),
        ]))

      snapshot = try launch("slider")
      guard
        let slider = snapshot["nodes"].elements.first(where: {
          $0["role"] == .string("slider") && $0["enabled"].boolValue == true
            && ($0["bounds"]["y"].doubleValue ?? 0) > 180
        })
      else {
        throw ToolError.message("slider: no enabled slider below the header")
      }
      let bounds = slider["bounds"]
      let moved = (bounds["x"].doubleValue ?? 0) + (bounds["width"].doubleValue ?? 0) * 0.3
      try tap(snapshot, slider.setting("bounds", to: bounds.setting("x", to: .double(moved))))
      let adjusted = try wait { state in
        state["nodes"].elements.contains {
          $0["id"] == slider["id"] && $0["value"] != slider["value"]
        }
      }
      checks.append(
        .object([("check", .string("slider touch updates value")), ("snapshot", adjusted)]))

      snapshot = try launch("contextMenu")
      guard
        let contextTarget = snapshot["nodes"].elements.first(where: {
          $0["label"] == .string("Right-click this surface")
        })
      else {
        throw ToolError.message("contextMenu: no long-press surface")
      }
      let menuBounds = contextTarget["bounds"]
      let scale = snapshot["scale"].doubleValue ?? 0
      let surface = snapshot["surface"]
      let menuX = pythonRound(
        (surface["x"].doubleValue ?? 0)
          + ((menuBounds["x"].doubleValue ?? 0) + (menuBounds["width"].doubleValue ?? 0) / 2)
          * scale)
      let menuY = pythonRound(
        (surface["y"].doubleValue ?? 0)
          + ((menuBounds["y"].doubleValue ?? 0) + (menuBounds["height"].doubleValue ?? 0) / 2)
          * scale)
      _ = try shell(["input", "swipe", menuX, menuY, menuX, menuY, 900])
      let opened = try wait { state in
        state["nodes"].elements.contains { $0["label"] == .string("Duplicate") }
      }
      checks.append(
        .object([("check", .string("long press opens context menu")), ("snapshot", opened)]))
      _ = try shell(["input", "keyevent", "KEYCODE_ESCAPE"])

      snapshot = try launch("textField")
      guard
        let field = snapshot["nodes"].elements.first(where: {
          $0["role"] == .string("textField") && $0["value"] == .string("GuavaUI")
        })
      else {
        throw ToolError.message("textField: no GuavaUI field")
      }
      try tap(snapshot, field)
      _ = try wait { !$0["editor"].isNull }

      func action(_ name: String, _ values: [(String, JSON)]) throws {
        var command: [any CustomStringConvertible] = [
          "am", "broadcast", "-a", "com.guava.probe.DEMO_INPUT",
          "-p", package, "--es", "demoAction", name,
        ]
        for (key, value) in values {
          if case .int(let number) = value {
            command += ["--ei", key, number]
          } else {
            command += ["--es", key, value.stringValue ?? ""]
          }
        }
        _ = try shell(command)
      }

      try action("select", [("start", .int(0)), ("end", .int(7))])
      try action("commit", [("text", .string("Android你好"))])
      _ = try wait { $0["editor"]["text"] == .string("Android你好") }
      try action("compose", [("text", .string("世界"))])
      _ = try wait { ($0["editor"]["compositionStart"].intValue ?? -1) >= 0 }
      try action("commit", [("text", .string("世界"))])
      let committed = try wait { $0["editor"]["text"] == .string("Android你好世界") }
      checks.append(
        .object([
          ("check", .string("TextField selection, replacement and Chinese composition")),
          ("snapshot", committed),
        ]))
      _ = try screenshot("textfield-edited")
      _ = try shell(["input", "keyevent", "KEYCODE_HOME"])
      Thread.sleep(forTimeInterval: 0.5)
      let paused = try read()
      Thread.sleep(forTimeInterval: 0.3)
      guard (try read())["frames"].doubleValue == paused["frames"].doubleValue else {
        throw ToolError.message("background Gallery keeps submitting frames")
      }
      _ = try shell([
        "am", "start", "-W", "-n", "com.guava.probe/.MainActivity", "--ez", "snapshots", "true",
      ])
      let resumed = try wait { state in
        state["session"] == committed["session"] && state["page"] == .string("textField")
          && (state["frames"].doubleValue ?? 0) > (paused["frames"].doubleValue ?? 0)
      }
      guard
        resumed["nodes"].elements.contains(where: {
          $0["role"] == .string("textField") && $0["value"] == .string("Android你好世界")
        })
      else {
        throw ToolError.message("restored TextField lost its edited value")
      }
      checks.append(
        .object([
          ("check", .string("background retains Gallery control state")), ("snapshot", resumed),
        ]))

      let viewport = resumed["controls"]["gallery-content"]
      let viewportScale = resumed["scale"].doubleValue ?? 0
      let origin = resumed["surface"]
      let scrollX = pythonRound(
        (origin["x"].doubleValue ?? 0)
          + ((viewport["x"].doubleValue ?? 0) + (viewport["width"].doubleValue ?? 0) * 0.85)
          * viewportScale)
      let scrollY = pythonRound(
        (origin["y"].doubleValue ?? 0)
          + ((viewport["y"].doubleValue ?? 0) + (viewport["height"].doubleValue ?? 0) * 0.85)
          * viewportScale)
      let lift = pythonRound((viewport["height"].doubleValue ?? 0) * 0.6 * viewportScale)
      _ = try shell(["input", "swipe", scrollX, scrollY, scrollX, scrollY - lift, 500])
      let scrolled = try wait { state in
        state["nodes"].elements.contains { $0["label"] == .string("Names and emoji") }
      }
      checks.append(
        .object([
          ("check", .string("finger scrolling reveals clipped fields")), ("snapshot", scrolled),
        ]))
    }

    let pid = try shell(["pidof", package]).trimmingCharacters(in: .whitespacesAndNewlines)
    let log = try Command.output(
      adb + ["logcat", "-d", "--pid=" + pid, "-s", "Guava:I", "AndroidRuntime:E", "*:S"])
    try Fs.write(log, to: directory.appendingPathComponent("app.log"))
    guard !log.contains("FAIL"), !log.contains("FATAL") else {
      throw ToolError.message(String(log.suffix(4000)))
    }
    let report = JSON.object([
      ("passed", .bool(true)), ("pages", .int(pages.count)), ("checks", .array(checks)),
    ])
    try Fs.write(report.prettyPrinted() + "\n", to: directory.appendingPathComponent("report.json"))
    Terminal.info("Gallery checks passed: \(directory.appendingPathComponent("report.json").path)")
  }

  /// `re.findall(r'\.init\(\.(\w+),', GalleryCatalog.swift)`.
  private static func catalog() throws -> [String] {
    let url = AndroidTools.guavaSDKRoot.appendingPathComponent(
      "Examples/Sources/GalleryContent/GalleryCatalog.swift")
    let text = try Fs.text(url)
    let pattern = try NSRegularExpression(pattern: "\\.init\\(\\.(\\w+),")
    let range = NSRange(text.startIndex..., in: text)
    return pattern.matches(in: text, range: range).compactMap { match in
      guard let capture = Range(match.range(at: 1), in: text) else { return nil }
      return String(text[capture])
    }
  }
}
