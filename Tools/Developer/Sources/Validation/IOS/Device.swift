#if os(macOS)
  internal import Foundation
  internal import ToolSupport

  /// Thin, typed wrapper over the `xcrun simctl` device lifecycle. Every command
  /// is passed as an argument vector; no shell string is interpreted.
  struct Device {
    /// One available iOS runtime, ordered by its parsed version.
    struct Runtime {
      let identifier: String
      let version: [Int]
    }

    let udid: String

    /// Creates an isolated simulator from the newest available device type so a
    /// validation run never disturbs a developer's own device.
    static func createIsolated() throws -> Device {
      let devices = (try json(["list", "devices", "available", "--json"])["devices"] as? [String: Any]) ?? [:]
      let configuration = try configuration(runtimes: availableRuntimes(), devices: devices)
      let udid = try simctl([
        "create", "GuavaStudio UI validation", configuration.deviceType, configuration.runtime,
      ])
      return Device(udid: udid)
    }

    /// Existing available devices identify the runtime/type combinations this Xcode supports.
    static func configuration(runtimes: [Runtime], devices: [String: Any]) throws
      -> (runtime: String, deviceType: String)
    {
      for runtime in runtimes {
        for entry in (devices[runtime.identifier] as? [[String: Any]]) ?? [] {
          guard let name = entry["name"] as? String, name.hasPrefix("iPhone"),
            let type = entry["deviceTypeIdentifier"] as? String
          else { continue }
          return (runtime.identifier, type)
        }
      }
      throw ToolError.message("No compatible available iPhone simulator")
    }

    /// Prints the UDID of the first available device named like `prefix`, newest
    /// runtime first. Falls back to any runtime when the ordered scan misses.
    static func firstUDID(prefix: String) throws -> String {
      let devices =
        (try json(["list", "devices", "available", "--json"])["devices"] as? [String: Any]) ?? [:]
      for runtime in try availableRuntimes() {
        if let entry = match(in: devices[runtime.identifier], prefix: prefix) { return entry }
      }
      for value in devices.values {
        if let entry = match(in: value, prefix: prefix) { return entry }
      }
      throw ToolError.message("No available simulator device starting with '\(prefix)'")
    }

    /// Reads `CFBundleIdentifier` from the bundle's `Info.plist`.
    static func bundleIdentifier(of app: URL) throws -> String {
      let data = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
      guard
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: Any],
        let identifier = plist["CFBundleIdentifier"] as? String
      else {
        throw ToolError.message("\(app.path)/Info.plist has no CFBundleIdentifier")
      }
      return identifier
    }

    /// `bootstatus -b` boots a shutdown device and blocks until it is ready.
    func boot() throws { try simctl(["bootstatus", udid, "-b"]) }
    func install(_ app: URL) throws { try simctl(["install", udid, app.path]) }
    func launch(_ identifier: String) throws {
      try simctl(["launch", "--terminate-running-process", udid, identifier])
    }
    func screenshot(to url: URL) throws { try simctl(["io", udid, "screenshot", "--display=1", url.path]) }

    /// Best-effort teardown; an already-shutdown device still deletes cleanly.
    func dispose() {
      _ = try? simctl(["shutdown", udid])
      _ = try? simctl(["delete", udid])
    }

    private static func availableRuntimes() throws -> [Runtime] {
      let entries =
        (try json(["list", "runtimes", "--json"])["runtimes"] as? [[String: Any]]) ?? []
      return entries.compactMap { entry -> Runtime? in
        guard entry["isAvailable"] as? Bool == true,
          let identifier = entry["identifier"] as? String, identifier.contains(".iOS-"),
          let version = entry["version"] as? String
        else { return nil }
        return Runtime(
          identifier: identifier, version: version.split(separator: ".").compactMap { Int($0) })
      }.sorted { lhs, rhs in
        for (left, right) in zip(lhs.version, rhs.version) where left != right {
          return left > right
        }
        return lhs.version.count > rhs.version.count
      }
    }

    private static func match(in value: Any?, prefix: String) -> String? {
      for entry in (value as? [[String: Any]]) ?? [] {
        if let name = entry["name"] as? String, name.hasPrefix(prefix),
          let udid = entry["udid"] as? String
        {
          return udid
        }
      }
      return nil
    }

  }

  @discardableResult
  private func simctl(_ arguments: [String]) throws -> String {
    try Shell.output(["xcrun", "simctl"] + arguments)
  }

  /// `simctl --json` output is a JSON object; anything else is a hard failure.
  private func json(_ arguments: [String]) throws -> [String: Any] {
    let data = Data(try simctl(arguments).utf8)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ToolError.message(
        "xcrun simctl \(arguments.joined(separator: " ")) did not produce JSON")
    }
    return object
  }
#endif
