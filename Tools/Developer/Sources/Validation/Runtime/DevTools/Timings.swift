internal import Foundation
internal import ToolSupport

/// Port of `scripts/record-editor-timings.swift`: observe the real window
/// submission path without enabling mirror readbacks. Also called in-process
/// by the editor loop.
enum RecordTimings {
  static let usage = "guava-dev validate record-timings PORT OUTPUT.json FRAMES WARMUP"

  static func run(_ arguments: [String]) throws {
    if arguments.contains("-h") || arguments.contains("--help") {
      Terminal.info(usage)
      return
    }
    guard arguments.count == 4, let port = UInt16(arguments[0]), port > 0,
      let count = Int(arguments[2]), count > 0,
      let warmup = Int(arguments[3]), warmup >= 0
    else {
      throw ToolError.message("Usage: \(usage)")
    }
    try record(
      port: port, destination: URL(fileURLWithPath: arguments[1]), frames: count, warmup: warmup)
  }

  static func record(port: UInt16, destination: URL, frames count: Int, warmup: Int) throws {
    #if !canImport(Darwin)
      throw ToolError.message("DevTools timing requires macOS")
    #else
      try AsyncBridge.wait {
        try await perform(port: port, destination: destination, count: count, warmup: warmup)
      }
    #endif
  }

  #if canImport(Darwin)
    private static func perform(port: UInt16, destination: URL, count: Int, warmup: Int)
      async throws
    {
      guard let endpoint = DevToolsSocket.loopback(port: port, token: false) else {
        throw ToolError.message("Invalid DevTools endpoint")
      }
      let connection = DevToolsSocket(
        url: endpoint, timeout: nil, maximumMessageSize: 32 * 1024 * 1024)
      defer { connection.close() }

      let hello = try await connection.receiveEnvelope()
      guard hello["type"] as? String == "hello",
        let capabilities = (hello["payload"] as? [String: Any])?["capabilities"] as? [String],
        capabilities.contains("timing")
      else {
        throw ToolError.message("DevTools timing is unavailable")
      }
      try await connection.send(["type": "timing.subscribe", "id": 1])

      var skipped = 0
      var frames: [[String: Any]] = []
      var started: UInt64 = 0
      while frames.count < count {
        let envelope = try await connection.receiveEnvelope()
        guard envelope["type"] as? String == "timing.frame",
          let payload = envelope["payload"] as? [String: Any]
        else { continue }
        if skipped < warmup {
          skipped += 1
          continue
        }
        if frames.isEmpty { started = DispatchTime.now().uptimeNanoseconds }
        frames.append(payload)
      }
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
      try await connection.send(["type": "timing.unsubscribe", "id": 2])
      while true {
        if try await connection.receiveEnvelope()["type"] as? String == "timing.unsubscribe.ok" {
          break
        }
      }

      func summary(_ key: String) throws -> [String: Any] {
        let values = try frames.map { frame -> Double in
          guard let number = frame[key] as? NSNumber else {
            throw ToolError.message("Timing frame is missing \(key)")
          }
          return number.doubleValue
        }.sorted()
        return [
          "p50": values[Int(ceil(Double(count) * 0.5)) - 1],
          "p95": values[Int(ceil(Double(count) * 0.95)) - 1],
          "minimum": values[0], "maximum": values[count - 1],
        ]
      }
      let presented = frames.filter { JSON.boolean($0["presented"]) == true }.count
      let report: [String: Any] = [
        "hello": hello, "warmup": warmup, "sampleCount": count,
        "source":
          "Application real-window layout, draw-list construction, submission and present calls; mirror disabled",
        "includesGPUCompletionTimestamp": false, "includesCompositorTimestamp": false,
        "streamElapsedSeconds": elapsed, "streamFramesPerSecond": Double(count - 1) / elapsed,
        "presentedFrames": presented, "unpresentedFrames": count - presented,
        "layoutMs": try summary("layoutMs"), "drawMs": try summary("drawMs"),
        "presentMs": try summary("presentMs"), "totalMs": try summary("totalMs"),
        "nodeCount": try summary("nodeCount"), "batchCount": try summary("batchCount"),
        "frames": frames,
      ]
      try JSON.write(report, to: destination, pretty: true)
      guard presented == count else {
        throw ToolError.message(
          "Only \(presented) / \(count) window frames were submitted/presented; benchmark rejected. Report: \(destination.path)"
        )
      }
      Terminal.info("Recorded \(count) presented window frames: \(destination.path)")
    }
  #endif
}
