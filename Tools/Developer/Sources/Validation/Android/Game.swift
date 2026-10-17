internal import Foundation
internal import ToolSupport

/// Port of `scripts/android/verify-game.py`: exercises the exported CrystalRush
/// APK through its native scene, script HUD, touch gameplay and lifecycle.
enum GameOperation {
  static func run(_ arguments: [String]) throws {
    let parsed = try ParsedArguments.parse(
      arguments,
      options: [
        OptionDefinition("--serial", arity: 1),
        OptionDefinition("--android-sdk", arity: 1),
        OptionDefinition("--package", arity: 1),
      ], positionals: 0)
    let package = parsed.value("--package") ?? "com.guava.game.crystalrush"
    let adb = try AndroidTools.adbDevice(
      AndroidTools.sdkRoot(parsed.value("--android-sdk")), parsed.value("--serial"))
    let directory = try AndroidTools.makeRunDirectory("game-run-")
    var checks: [JSON] = []

    func shell(_ values: [any CustomStringConvertible]) throws -> String {
      try Command.output(adb + ["shell", AndroidTools.shellCommand(values)])
    }

    func read() throws -> JSON {
      try JSON.parse(
        try Command.output(adb + ["exec-out", "run-as", package, "cat", "files/demo-state.json"]))
    }

    func wait(_ predicate: (JSON) -> Bool, _ name: String) throws -> JSON {
      let deadline = AndroidTools.uptime + 30
      var last: JSON = .null
      while AndroidTools.uptime < deadline {
        do {
          last = try read()
          if predicate(last) {
            checks.append(.object([("check", .string(name)), ("snapshot", last)]))
            Terminal.info("PASS " + name)
            return last
          }
        } catch {}
        Thread.sleep(forTimeInterval: 0.2)
      }
      throw ToolError.message("\(name): \(last.prettyPrinted())")
    }

    func screenshot(_ name: String) throws {
      let data = try Command.data(adb + ["exec-out", "screencap", "-p"])
      let path = directory.appendingPathComponent(name + ".png")
      try Fs.write(data, to: path)
      let image = try Bitmap.load(path)
      let bounds = try read()["surface"]
      let crop = image.cropped(
        bounds["x"].roundedInt, bounds["y"].roundedInt,
        bounds["x"].roundedInt + bounds["width"].roundedInt,
        bounds["y"].roundedInt + bounds["height"].roundedInt)
      guard crop.maxChannelStdDev > 20 else { throw ToolError.message("Game image is blank") }
    }

    func action(_ name: String, _ scancode: Int) throws {
      _ = try shell([
        "am", "broadcast", "-a", "com.guava.probe.DEMO_INPUT", "-p", package,
        "--es", "demoAction", name, "--ei", "scancode", scancode,
      ])
    }

    func playingHUD(_ snapshot: JSON) -> Bool {
      snapshot["game"]["hud"].elements.contains { ($0.stringValue ?? "").contains("按空格开始") }
    }

    var previous: JSON = .null
    do { previous = try read()["session"] } catch { previous = .null }
    _ = try shell([
      "am", "start", "-W", "-S", "-n", package + "/com.guava.probe.MainActivity",
      "--ei", "orientation", 0, "--ez", "snapshots", "true",
    ])
    let ready = try wait(
      { snapshot in
        snapshot["session"] != previous && snapshot["mode"] == .string("game")
          && snapshot["game"]["rendered"].isTruthy && playingHUD(snapshot)
      }, "exported scene and Chinese HUD render")
    guard ready["game"]["scripts"].intValue == 1, ready["game"]["entities"].intValue == 60 else {
      throw ToolError.message("exported scene is missing its script or entity count")
    }
    try screenshot("ready")

    _ = try shell(["uiautomator", "dump", "/data/local/tmp/guava-game-ui.xml"])
    let buttons = try parseButtons(try shell(["cat", "/data/local/tmp/guava-game-ui.xml"]))
    guard let start = buttons["start"] else {
      throw ToolError.message("game HUD has no Start button")
    }
    _ = try shell(["input", "tap", start[0], start[1]])
    _ = try wait({ !playingHUD($0) }, "touch Start drives project script")

    try action("keyDown", 26)
    var moved = try wait(
      { ($0["game"]["player"].at(2).doubleValue ?? 0) < -0.5 }, "held W moves the scene player")
    try action("keyUp", 26)
    let before = moved["game"]["player"].at(0).doubleValue ?? 0
    guard let dButton = buttons["d →"] else { throw ToolError.message("game HUD has no D button") }
    _ = try shell(["input", "swipe", dButton[0], dButton[1], dButton[0], dButton[1], 700])
    moved = try wait(
      { ($0["game"]["player"].at(0).doubleValue ?? 0) > before + 0.5 },
      "touch D moves player continuously")
    try screenshot("playing")

    _ = try shell(["input", "keyevent", "KEYCODE_HOME"])
    Thread.sleep(forTimeInterval: 0.5)
    let paused = try read()
    Thread.sleep(forTimeInterval: 0.5)
    guard (try read())["frames"].doubleValue == paused["frames"].doubleValue else {
      throw ToolError.message("background keeps ticking the game")
    }
    _ = try shell([
      "am", "start", "-W", "-n", package + "/com.guava.probe.MainActivity", "--ez", "snapshots",
      "true",
    ])
    let resumed = try wait(
      { snapshot in
        snapshot["session"] == moved["session"]
          && (snapshot["frames"].doubleValue ?? 0) > (paused["frames"].doubleValue ?? 0)
      }, "resume retains the live game session")
    guard resumed["game"]["entities"].intValue == 60 else {
      throw ToolError.message("resume changed the entity count")
    }

    _ = try shell([
      "am", "start", "-W", "-n", package + "/com.guava.probe.MainActivity", "--ei", "orientation",
      1, "--ez", "snapshots", "true",
    ])
    _ = try wait(
      { snapshot in
        (snapshot["height"].doubleValue ?? 0) > (snapshot["width"].doubleValue ?? 0)
          && snapshot["session"] == resumed["session"] && snapshot["game"]["rendered"].isTruthy
      }, "rotation rebuilds Vulkan surface and retains simulation")
    try screenshot("portrait")
    _ = try shell([
      "am", "start", "-W", "-n", package + "/com.guava.probe.MainActivity", "--ei", "orientation",
      0, "--ez", "snapshots", "true",
    ])
    _ = try wait(
      { ($0["width"].doubleValue ?? 0) > ($0["height"].doubleValue ?? 0) },
      "landscape game surface restores")

    try action("keyDown", 21)
    try action("keyUp", 21)
    _ = try wait(
      { snapshot in
        snapshot["game"]["player"] == .array([.int(0), .double(0.6), .int(0)])
          && snapshot["game"]["hud"].elements.contains { ($0.stringValue ?? "").contains("50 秒") }
      }, "restart restores the round deterministically")
    try screenshot("restarted")

    let pid = try shell(["pidof", package]).trimmingCharacters(in: .whitespacesAndNewlines)
    let log = try Command.output(
      adb + ["logcat", "-d", "--pid=" + pid, "-s", "Guava:I", "AndroidRuntime:E", "*:S"])
    try Fs.write(log, to: directory.appendingPathComponent("app.log"))
    guard !log.contains("FAIL"), !log.contains("FATAL") else {
      throw ToolError.message(String(log.suffix(4000)))
    }
    let report = JSON.object([("passed", .bool(true)), ("checks", .array(checks))])
    try Fs.write(report.prettyPrinted() + "\n", to: directory.appendingPathComponent("report.json"))
    Terminal.info(
      "Exported game checks passed: \(directory.appendingPathComponent("report.json").path)")
  }

  /// Parses `uiautomator dump` far enough to find the on-screen buttons and
  /// their center points, like `ElementTree` plus `re.findall(r'\d+', bounds)`.
  static func parseButtons(_ xml: String) throws -> [String: [Int]] {
    let nodePattern = try NSRegularExpression(pattern: "<node\\b[^>]*>")
    let attributePattern = try NSRegularExpression(
      pattern: "([A-Za-z_][A-Za-z0-9_\\-]*)=\"([^\"]*)\"")
    let digitPattern = try NSRegularExpression(pattern: "\\d+")
    var buttons: [String: [Int]] = [:]
    for match in nodePattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
      guard let tagRange = Range(match.range, in: xml) else { continue }
      let tag = String(xml[tagRange])
      var attributes: [String: String] = [:]
      for attribute in attributePattern.matches(in: tag, range: NSRange(tag.startIndex..., in: tag))
      {
        guard let keyRange = Range(attribute.range(at: 1), in: tag),
          let valueRange = Range(attribute.range(at: 2), in: tag)
        else { continue }
        attributes[String(tag[keyRange])] = String(tag[valueRange])
      }
      guard attributes["class"] == "android.widget.Button", let text = attributes["text"],
        let bounds = attributes["bounds"]
      else { continue }
      let numbers = digitPattern.matches(
        in: bounds, range: NSRange(bounds.startIndex..., in: bounds)
      )
      .compactMap { Range($0.range, in: bounds) }
      .compactMap { Int(bounds[$0]) }
      guard numbers.count == 4 else { continue }
      buttons[text.lowercased()] = [(numbers[0] + numbers[2]) / 2, (numbers[1] + numbers[3]) / 2]
    }
    return buttons
  }
}
