internal import Foundation
internal import ToolSupport

/// Port of `scripts/android/verify-logging.py`: verifies a running Profile app's
/// Java/JNI/Swift journal and its lifecycle flush.
enum LoggingOperation {
  static func run(_ arguments: [String]) throws {
    let parsed = try ParsedArguments.parse(arguments, options: [], positionals: 1)
    let project = URL(fileURLWithPath: parsed.positionals[0]).standardizedFileURL

    let devtools = project.appendingPathComponent(".build/devtools")
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: devtools, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    let sessionFiles =
      entries
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      .map { $0.appendingPathComponent("session.json") }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
    let sessions = try sessionFiles.map { try JSON.parse(Fs.text($0)) }
      .filter { $0["platform"] == .string("android") }
    guard sessions.count == 1 else { throw ToolError.message("Expected one live Android session") }
    let session = sessions[0]
    let package = session["application"]["id"].stringValue ?? ""
    let pid = session["runtime"]["pid"]
    let device = session["device"]
    let adb = [device["adb"].stringValue ?? "", "-s", device["serial"].stringValue ?? ""]

    /// `shell`: adb receives the device command as separate arguments here.
    func shell(_ values: [String]) throws -> String {
      try Command.output(adb + ["shell"] + values)
    }

    /// The Python `finally` foregrounds the app on every exit path.
    func restart() {
      _ = try? shell(["am", "start", "-n", package + "/com.guava.probe.MainActivity"])
    }

    func records() throws -> [JSON] {
      let paths = try shell(["run-as", package, "find", "files/logs", "-name", "events.jsonl"])
        .splitLines()
      var result: [JSON] = []
      for path in paths {
        let data = try Command.output(adb + ["exec-out", "run-as", package, "cat", path])
        let current = try data.splitLines()
          .map { try JSON.parse($0) }
          .filter { $0["process"]["pid"] == pid }
        let sequences = current.compactMap { $0["sequence"].intValue }
        guard sequences == sequences.sorted() else {
          throw ToolError.message("journal sequences are not ordered")
        }
        result.append(contentsOf: current)
      }
      return result
    }

    let initial = try records()
    guard !initial.isEmpty else { throw ToolError.message("No application journal") }
    guard Set(initial.map { $0["process"]["runID"].stringValue ?? "" }).count == 1 else {
      throw ToolError.message("Startup logs kept a provisional run ID")
    }
    guard initial.contains(where: { $0["label"] == .string("com.guava.engine.rhi") }) else {
      throw ToolError.message("No com.guava.engine.rhi record")
    }
    let java = initial.filter { $0["metadata"]["origin"] == .string("java") }
    guard !java.isEmpty,
      java.allSatisfy({
        $0["location"]["file"] == .string("RuntimeLog.java")
          && $0["location"]["source"] == .string("JNI")
      })
    else {
      throw ToolError.message(
        "Java records are missing or not attributed to RuntimeLog.java over JNI")
    }
    let sequence = initial.compactMap { $0["sequence"].intValue }.max() ?? 0

    var flushed: [JSON] = []
    _ = try shell(["input", "keyevent", "KEYCODE_HOME"])
    do {
      let deadline = AndroidTools.uptime + 5
      var observed = false
      while AndroidTools.uptime < deadline {
        flushed = try records()
        if flushed.contains(where: {
          ($0["sequence"].intValue ?? 0) > sequence && $0["message"] == .string("Activity paused")
        }) {
          observed = true
          break
        }
        Thread.sleep(forTimeInterval: 0.05)
      }
      guard observed else {
        throw ToolError.message("onPause did not flush the Java lifecycle record")
      }
    } catch {
      restart()
      throw error
    }
    restart()

    let summary = JSON.object([
      ("pid", pid),
      ("runID", initial[0]["process"]["runID"]),
      ("records", .int(flushed.count)),
      (
        "modules",
        .array(Set(flushed.compactMap { $0["label"].stringValue }).sorted().map { .string($0) })
      ),
      ("javaJNI", .bool(true)),
      ("pauseFlush", .bool(true)),
    ])
    Terminal.info(summary.prettyPrinted())
  }
}
