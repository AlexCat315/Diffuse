internal import Foundation
internal import ToolSupport

/// Port of `scripts/android/verify-demo.py`: validates the SharedCounter APK
/// through pixels, touch, Compose state, IME input and Activity recreation.
enum DemoOperation {
  private static let package = "com.guava.probe"

  static func run(_ arguments: [String]) throws {
    let parsed = try ParsedArguments.parse(
      arguments,
      options: [
        OptionDefinition("--android-sdk", arity: 1),
        OptionDefinition("--serial", arity: 1),
      ], positionals: 0)
    let adb = try AndroidTools.adbDevice(
      AndroidTools.sdkRoot(parsed.value("--android-sdk")), parsed.value("--serial"))
    let directory = try AndroidTools.makeRunDirectory("demo-run-")
    var checkpoints: [JSON] = []

    /// `read`: one snapshot written by the debug app.
    func read() throws -> JSON {
      let data = try Command.output(
        adb + ["exec-out", "run-as", package, "cat", "files/demo-state.json"],
        discardError: true)
      return try JSON.parse(data)
    }

    /// `wait`: polls until the predicate holds, recording a checkpoint.
    func wait(_ predicate: (JSON) -> Bool, _ description: String) throws -> JSON {
      let deadline = AndroidTools.uptime + 15
      var last: JSON = .null
      while AndroidTools.uptime < deadline {
        do {
          last = try read()
          if predicate(last) {
            checkpoints.append(.object([("check", .string(description)), ("snapshot", last)]))
            Terminal.info("PASS " + description)
            return last
          }
        } catch {}
        Thread.sleep(forTimeInterval: 0.2)
      }
      throw ToolError.message("\(description): timed out; latest state=\(last.prettyPrinted())")
    }

    func shell(_ values: [any CustomStringConvertible]) throws {
      try Command.run(adb + ["shell", AndroidTools.shellCommand(values)])
    }

    func action(_ name: String, _ text: String? = nil) throws {
      var values: [any CustomStringConvertible] = [
        "am", "broadcast", "-a", "com.guava.probe.DEMO_INPUT",
        "-p", package, "--es", "demoAction", name,
      ]
      if let text { values += ["--es", "text", text] }
      try shell(values)
    }

    /// Control center in device pixels, using Python's rounding.
    func center(_ snapshot: JSON, _ name: String) -> [Int] {
      let control = snapshot["controls"][name]
      let surface = snapshot["surface"]
      let scale = snapshot["scale"].doubleValue ?? 0
      let x =
        (surface["x"].doubleValue ?? 0)
        + ((control["x"].doubleValue ?? 0) + (control["width"].doubleValue ?? 0) / 2) * scale
      let y =
        (surface["y"].doubleValue ?? 0)
        + ((control["y"].doubleValue ?? 0) + (control["height"].doubleValue ?? 0) / 2) * scale
      return [pythonRound(x), pythonRound(y)]
    }

    func tap(_ snapshot: JSON, _ name: String) throws {
      let point = center(snapshot, name)
      try shell(["input", "tap", point[0], point[1]])
    }

    func screenshot(_ name: String) throws -> Bitmap {
      let path = directory.appendingPathComponent(name + ".png")
      try Command.run(adb + ["exec-out", "screencap", "-p"], stdout: path)
      return try Bitmap.load(path)
    }

    /// Ink count plus content hash of the counter glyph crop.
    func counterPixels(_ image: Bitmap, _ snapshot: JSON) throws -> String {
      let bounds = snapshot["controls"]["counter.value"]
      let surface = snapshot["surface"]
      let scale = snapshot["scale"].doubleValue ?? 0
      let x = (surface["x"].doubleValue ?? 0) + (bounds["x"].doubleValue ?? 0) * scale
      let y = (surface["y"].doubleValue ?? 0) + (bounds["y"].doubleValue ?? 0) * scale
      let width = min(160, bounds["width"].doubleValue ?? 0)
      let height = bounds["height"].doubleValue ?? 0
      let crop = image.cropped(
        pythonRound(x), pythonRound(y),
        pythonRound(x + width * scale), pythonRound(y + height * scale))
      let ink = crop.inkCount()
      guard ink >= 100 else {
        throw ToolError.message("Counter glyphs are absent from screenshot: \(ink) ink pixels")
      }
      return crop.sha256Hex()
    }

    var previous: JSON = .null
    do { previous = try read()["session"] } catch { previous = .null }
    try shell([
      "am", "start", "-W", "-S", "-n", "com.guava.probe/.MainActivity", "--ei", "orientation", 0,
      "--es", "mode", "counter", "--ez", "snapshots", "true",
    ])
    let initial = try wait(
      { snapshot in
        snapshot["session"] != previous
          && snapshot["state"]
            == .object([("count", .string("0")), ("dark", .string("false")), ("note", .string(""))])
      }, "fresh shared Compose scene")
    guard (initial["typography"]["fonts"].intValue ?? 0) >= 2,
      initial["typography"]["missingGlyphs"].intValue == 0
    else {
      throw ToolError.message(
        "fresh scene typography is incomplete: \(initial["typography"].prettyPrinted())")
    }
    guard (initial["typography"]["atlasPixels"].intValue ?? 0) > 1000,
      (initial["indices"].intValue ?? 0) > 1000
    else {
      throw ToolError.message("fresh scene did not upload its glyph atlas or draw list")
    }
    let zero = try counterPixels(try screenshot("counter-zero"), initial)
    try tap(initial, "counter.increment")
    let one = try wait({ $0["state"]["count"] == .string("1") }, "touch increments State")
    guard try counterPixels(try screenshot("counter-one"), one) != zero else {
      throw ToolError.message("State changed without changing the displayed glyph")
    }
    try tap(one, "counter.increment")
    let two = try wait(
      { $0["state"]["count"] == .string("2") }, "recomposition preserves button routes")
    // A captured drag released outside must not invoke the click action.
    let increment = center(two, "counter.increment")
    try shell(["input", "swipe", increment[0], increment[1], 2, two["surface"]["y"].plus(4), 300])
    Thread.sleep(forTimeInterval: 0.3)
    guard try read()["state"]["count"] == .string("2") else {
      throw ToolError.message("a captured drag invoked the click action")
    }
    try tap(two, "counter.theme")
    let dark = try wait({ $0["state"]["dark"] == .string("true") }, "theme recomposes")
    let image = try screenshot("dark-theme")
    let cornerX = (dark["surface"]["x"].intValue ?? 0) + 4
    let cornerY = (dark["surface"]["y"].intValue ?? 0) + 4
    guard image.maxChannel(cornerX, cornerY) < 80 else {
      throw ToolError.message("Theme state changed without painting a dark background")
    }
    try tap(dark, "counter.note")
    _ = try wait({ $0["focused"] == .string("counter.note") }, "GuavaUI note receives focus")
    // Verify that the real IME is bound to our view, then inject physical keys.
    // Some IMEs keep the word in their candidate window until Space selects it.
    let ime = try Command.output(adb + ["shell", "dumpsys", "input_method"])
    guard ime.contains("connection=com.guava.probe.TextInputConnection"),
      ime.contains("mInputShown=true")
    else {
      throw ToolError.message("the Android IME is not bound to com.guava.probe.TextInputConnection")
    }
    try shell(["input", "text", "Vulkan"])
    let noteDeadline = AndroidTools.uptime + 2
    while ((try read())["state"]["note"].stringValue ?? "").isEmpty,
      AndroidTools.uptime < noteDeadline
    {
      Thread.sleep(forTimeInterval: 0.2)
    }
    if ((try read())["state"]["note"].stringValue ?? "").isEmpty {
      try shell(["input", "keyevent", "KEYCODE_SPACE"])
    }
    let entered = try wait(
      { ["Vulkan", "Vulkan "].contains($0["state"]["note"].stringValue ?? "") },
      "active Android IME commits injected keys")
    if (entered["state"]["note"].stringValue ?? "").hasSuffix(" ") {
      try action("delete")
      _ = try wait({ $0["state"]["note"] == .string("Vulkan") }, "remove IME word separator")
    }
    try action("compose", "你好")
    _ = try wait(
      { $0["preedit"] == .string("你好") && $0["state"]["note"] == .string("Vulkan") },
      "IME composition remains transient")
    try action("compose", "")
    _ = try wait(
      { !$0["preedit"].isTruthy && $0["state"]["note"] == .string("Vulkan") },
      "IME composition cancellation")
    try action("compose", "你好")
    _ = try wait({ $0["preedit"] == .string("你好") }, "IME composition replacement")
    try action("commit", "你好")
    _ = try wait(
      { $0["state"]["note"] == .string("Vulkan你好") && !$0["preedit"].isTruthy },
      "IME commits Unicode once")
    try action("commit", "🚀")
    _ = try wait(
      { $0["state"]["note"] == .string("Vulkan你好🚀") }, "JNI preserves UTF-16 surrogate pairs")
    try action("delete")
    _ = try wait(
      { $0["state"]["note"] == .string("Vulkan你好") }, "backspace removes one Unicode grapheme")
    try action("compose", "e\u{0301}")
    _ = try wait({ $0["preedit"] == .string("e\u{0301}") }, "combining mark preedit")
    try action("finish")
    _ = try wait(
      { $0["state"]["note"] == .string("Vulkan你好e\u{0301}") && !$0["preedit"].isTruthy },
      "finishComposingText commits once")
    try action("delete")
    _ = try wait(
      { $0["state"]["note"] == .string("Vulkan你好") }, "backspace preserves grapheme boundaries")
    try action("compose", "未提交")
    let current = try wait({ $0["preedit"] == .string("未提交") }, "pending text before recreation")
    let expected = current["state"]
    try action("recreate")
    let recreated = try wait(
      { snapshot in
        snapshot["session"] == current["session"]
          && (snapshot["frames"].doubleValue ?? 0) > (current["frames"].doubleValue ?? 0)
          && snapshot["state"] == expected && !snapshot["preedit"].isTruthy
      }, "Activity recreation retains scene and clears transient input")
    try shell(["input", "keyevent", "KEYCODE_HOME"])
    Thread.sleep(forTimeInterval: 0.5)
    try shell([
      "am", "start", "-W", "-n", "com.guava.probe/.MainActivity", "--ez", "snapshots", "true",
    ])
    _ = try wait(
      { snapshot in
        snapshot["session"] == recreated["session"]
          && (snapshot["frames"].doubleValue ?? 0) > (recreated["frames"].doubleValue ?? 0)
          && snapshot["state"] == expected
      }, "foreground restores surface and demo state")
    try shell([
      "am", "start", "-W", "-n", "com.guava.probe/.MainActivity", "--ei", "orientation", 1, "--ez",
      "snapshots", "true",
    ])
    _ = try wait(
      { snapshot in
        (snapshot["height"].doubleValue ?? 0) > (snapshot["width"].doubleValue ?? 0)
          && snapshot["state"] == expected
      }, "portrait relayout retains demo state")
    _ = try screenshot("portrait")
    try shell([
      "am", "start", "-W", "-n", "com.guava.probe/.MainActivity", "--ei", "orientation", 0, "--ez",
      "snapshots", "true",
    ])
    let landscape = try wait(
      { snapshot in
        (snapshot["width"].doubleValue ?? 0) > (snapshot["height"].doubleValue ?? 0)
          && snapshot["state"] == expected
      }, "landscape relayout retains demo state")
    try tap(landscape, "counter.reset")
    let reset = try wait(
      { $0["state"]["count"] == .string("0") && $0["state"]["note"] == expected["note"] },
      "reset changes only counter")
    guard reset["typography"]["missingGlyphs"].intValue == 0 else {
      throw ToolError.message("reset lost glyphs: \(reset["typography"].prettyPrinted())")
    }
    Thread.sleep(forTimeInterval: 0.8)
    guard (try read())["frames"].doubleValue == reset["frames"].doubleValue else {
      throw ToolError.message("Idle scene keeps submitting GPU frames")
    }
    _ = try screenshot("landscape")
    // Restore sensor orientation after the explicit orientation checks.
    try shell([
      "am", "start", "-W", "-n", "com.guava.probe/.MainActivity", "--ei", "orientation", -1, "--ez",
      "snapshots", "true",
    ])
    _ = try wait(
      { $0["state"]["count"] == .string("0") && $0["state"]["note"] == expected["note"] },
      "sensor orientation restored")
    let pid = try Command.output(adb + ["shell", "pidof", package]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let log = try Command.output(adb + ["logcat", "-d", "--pid=" + pid, "-s", "Guava:I", "*:S"])
    try Fs.write(log, to: directory.appendingPathComponent("app.log"))
    guard !log.contains("FAIL") else { throw ToolError.message(log) }
    let report = JSON.object([("passed", .bool(true)), ("checks", .array(checkpoints))])
    try Fs.write(report.prettyPrinted() + "\n", to: directory.appendingPathComponent("report.json"))
    Terminal.info(
      "SharedCounter Android checks passed: \(directory.appendingPathComponent("report.json").path)"
    )
  }
}
