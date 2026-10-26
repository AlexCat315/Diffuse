internal import Foundation

#if os(macOS)
  internal import ToolSupport

  /// Drives `xcrun simctl` to select an iOS simulator and to verify that a built
  /// application renders real content instead of an empty frame.
  ///
  /// Replaces `scripts/ios/validate-app.py` together with its `FrameCheck.swift`
  /// helper. The first token of `arguments` selects the operation.
  public enum IOSSimulator {
    static let usage = """
      guava task ios-simulator -- <operation> [options]

        udid [--prefix NAME]      Print the UDID of an available simulator device
        validate APP [--simulator UDID]
                                  Install and launch a built .app and reject an empty frame

        --prefix NAME    Device name prefix to match; defaults to iPhone.
        --simulator UDID Reuse an existing simulator instead of creating an
                         isolated device from the newest available iOS runtime.
      """

    public static func run(_ arguments: [String]) throws {
      guard let operation = arguments.first else {
        throw ToolError.message("Missing operation; expected udid or validate")
      }
      let flags = Array(arguments.dropFirst())
      switch operation {
      case "udid": print(try udid(flags))
      case "validate": try validate(flags)
      case "-h", "--help": Terminal.info(usage)
      default:
        throw ToolError.message("Unknown operation '\(operation)'; expected udid or validate")
      }
    }

    /// Prints the UDID of the first available device whose name matches, newest
    /// iOS runtime first, so callers can boot it with `xcrun simctl`.
    private static func udid(_ arguments: [String]) throws -> String {
      let (options, positional) = try parse(arguments, allowed: ["--prefix"])
      guard positional.isEmpty else {
        throw ToolError.message("unrecognized arguments: \(positional.joined(separator: " "))")
      }
      return try Device.firstUDID(prefix: options["--prefix"] ?? "iPhone")
    }

    /// Boots a simulator (creating an isolated one when none is supplied),
    /// installs the bundle, launches it and inspects the first rendered frame.
    private static func validate(_ arguments: [String]) throws {
      let (options, positional) = try parse(arguments, allowed: ["--simulator"])
      guard positional.count == 1 else {
        throw ToolError.message("validate expects exactly one .app bundle path")
      }
      let app = URL(fileURLWithPath: positional[0]).standardizedFileURL
      let identifier = try Device.bundleIdentifier(of: app)
      if let existing = options["--simulator"] {
        try inspect(Device(udid: existing), app: app, identifier: identifier)
      } else {
        let device = try Device.createIsolated()
        defer { device.dispose() }
        try inspect(device, app: app, identifier: identifier)
      }
    }

    private static func inspect(_ device: Device, app: URL, identifier: String) throws {
      // bootstatus -b boots a shutdown simulator and waits for readiness.
      try device.boot()
      try device.install(app)
      try device.launch(identifier)
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("guava-ios-frame-\(UUID().uuidString)")
      try Fs.directory(directory)
      defer { try? Fs.remove(directory) }
      let screenshot = directory.appendingPathComponent("frame.png")
      // Wait for initial font/pipeline preparation and the first display tick.
      Thread.sleep(forTimeInterval: 5)
      try device.screenshot(to: screenshot)
      let colors = try Frame.distinctColors(in: screenshot)
      guard colors > 16 else {
        throw ToolError.message("iOS rendered an empty frame (\(colors) colors)")
      }
      Terminal.info("PASS iOS frame contains rendered controls (\(colors) colors)")
    }

    /// Splits a small, fixed option surface from positional arguments. Every
    /// option takes exactly one value, which keeps the parser total.
    private static func parse(_ arguments: [String], allowed: Set<String>) throws -> (
      [String: String], [String]
    ) {
      var options: [String: String] = [:]
      var positional: [String] = []
      var index = 0
      while index < arguments.count {
        let argument = arguments[index]
        if argument.hasPrefix("--") {
          guard allowed.contains(argument) else {
            throw ToolError.message("unrecognized argument: \(argument)")
          }
          index += 1
          guard index < arguments.count else {
            throw ToolError.message("missing value for \(argument)")
          }
          options[argument] = arguments[index]
        } else {
          positional.append(argument)
        }
        index += 1
      }
      return (options, positional)
    }
  }
#else
  internal import ToolSupport

  /// On platforms without a simulator, the operation exists only to fail clearly.
  public enum IOSSimulator {
    public static func run(_ arguments: [String]) throws {
      throw ToolError.message("iOS simulator control requires macOS")
    }
  }
#endif
