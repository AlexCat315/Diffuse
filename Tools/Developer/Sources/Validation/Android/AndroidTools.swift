internal import Foundation
internal import ToolSupport

/// Port of `scripts/android/common.py`: SDK/NDK discovery, the cross-compile
/// driver, device selection, and the single output directory every Android run
/// writes into.
enum AndroidTools {
  static var root: URL { Repository.root }

  /// `OUTPUT = ROOT / 'Engine/build/android-validation'`.
  static var output: URL { Repository.path("Engine/build/android-validation") }

  /// Monotonic-ish time source for the Python `time.monotonic()` deadlines.
  static var uptime: Double { ProcessInfo.processInfo.systemUptime }

  /// `sdk_root`: explicit flag, then `ANDROID_HOME`/`ANDROID_SDK_ROOT`, then
  /// the default per-user SDK location.
  static func sdkRoot(_ value: String?) throws -> URL {
    guard
      let requested = firstNonEmpty(
        value, ProcessInfo.processInfo.environment["ANDROID_HOME"],
        ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"],
        FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent("Library/Android/sdk").path)
    else {
      throw ToolError.message("Supply --android-sdk pointing to an Android SDK with platform-tools")
    }
    let root = URL(fileURLWithPath: requested).resolvingSymlinksInPath()
    let adb = root.appendingPathComponent("platform-tools/adb")
    guard FileManager.default.fileExists(atPath: adb.path) else {
      throw ToolError.message("Supply --android-sdk pointing to an Android SDK with platform-tools")
    }
    return root
  }

  /// `ndk_root`: explicit flag, then `ANDROID_NDK_HOME`, then the pinned
  /// r30 download under `OUTPUT`. Swift 6.4 requires exactly NDK r30.
  static func ndkRoot(_ value: String?) throws -> URL {
    guard
      let requested = firstNonEmpty(
        value, ProcessInfo.processInfo.environment["ANDROID_NDK_HOME"],
        output.appendingPathComponent("android-ndk-r30").path)
    else {
      throw ToolError.message("Swift 6.4 Android SDK requires NDK r30; supply --ndk")
    }
    let root = URL(fileURLWithPath: requested).resolvingSymlinksInPath()
    let properties = try Fs.text(root.appendingPathComponent("source.properties"))
    guard properties.range(of: "Pkg.Revision\\s*=\\s*30\\.", options: .regularExpression) != nil
    else {
      throw ToolError.message("Swift 6.4 Android SDK requires NDK r30; supply --ndk")
    }
    return root
  }

  /// `ndk_host`: the single prebuilt host toolchain, whose sysroot carries the
  /// `libc++_shared.so` the probe links against.
  static func ndkHost(_ ndk: URL) throws -> URL {
    let prebuilt = ndk.appendingPathComponent("toolchains/llvm/prebuilt")
    let hosts =
      (try? FileManager.default.contentsOfDirectory(at: prebuilt, includingPropertiesForKeys: nil))
      ?? []
    guard hosts.count == 1 else { throw ToolError.message("Expected one NDK host toolchain") }
    return hosts[0]
  }

  /// `build`: cross-compiles one Android product through the Swift CLI and
  /// returns the staged products directory. Production build ownership lives
  /// in `guava internal android-compile`; this only drives it.
  static func build(_ product: String, _ ndk: URL, configuration: String = "debug") throws -> URL {
    try Fs.directory(output)
    let result = output.appendingPathComponent("compile-\(UUID().uuidString).json")
    FileManager.default.createFile(atPath: result.path, contents: Data())
    defer { try? Fs.remove(result) }
    try Command.run([
      root.appendingPathComponent("GuavaUI/guava").path,
      "internal", "android-compile", "--sdk-root", root.appendingPathComponent("GuavaUI").path,
      "--product", product,
      "--ndk", ndk.path, "--" + configuration, "--result-file", result.path,
    ])
    let document = try JSON.parse(Fs.text(result))
    guard let products = document["products"].stringValue else {
      throw ToolError.message("android-compile did not report a products directory")
    }
    return URL(fileURLWithPath: products)
  }

  /// `adb_device`: resolves `[adb, '-s', serial]` for one authorized device.
  static func adbDevice(_ sdk: URL, _ serial: String?) throws -> [String] {
    let adb = sdk.appendingPathComponent("platform-tools/adb").path
    let listing = try Command.output([adb, "devices"])
    let ready = listing.splitLines().dropFirst().compactMap { line -> String? in
      let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
      return fields.count >= 2 && fields[1] == "device" ? fields[0] : nil
    }
    guard let selected = firstNonEmpty(serial, ready.count == 1 ? ready[0] : nil) else {
      throw ToolError.message("Connect exactly one authorized device, or supply --serial")
    }
    guard ready.contains(selected) else {
      throw ToolError.message("Android device \(selected) is not connected and authorized")
    }
    return [adb, "-s", selected]
  }

  /// Creates a unique directory under `OUTPUT`, matching `tempfile.mkdtemp`.
  static func makeRunDirectory(_ prefix: String) throws -> URL {
    try Fs.directory(output)
    let directory = output.appendingPathComponent("\(prefix)\(UUID().uuidString)")
    try Fs.directory(directory)
    return directory
  }

  /// `shlex.join(map(str, arguments))` for one device shell command.
  static func shellCommand(_ values: [any CustomStringConvertible]) -> String {
    values.map { shellQuote(String(describing: $0)) }.joined(separator: " ")
  }

  /// `shlex.quote`: leave safe words bare, otherwise single-quote and escape.
  static func shellQuote(_ value: String) -> String {
    if !value.isEmpty, value.allSatisfy(isShellSafe) { return value }
    return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }

  private static func isShellSafe(_ character: Character) -> Bool {
    guard character.isASCII else { return false }
    return character.isLetter || character.isNumber || "_@%+=:,./-".contains(character)
  }

  /// Returns the first non-nil, non-empty value, mirroring Python's
  /// `a or b or c` where an empty environment string is falsy.
  static func firstNonEmpty(_ candidates: String?...) -> String? {
    for candidate in candidates {
      if let candidate, !candidate.isEmpty { return candidate }
    }
    return nil
  }
}
