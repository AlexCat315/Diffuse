internal import Foundation
internal import ToolSupport

#if canImport(Darwin)
  private import Darwin
#elseif canImport(Glibc)
  private import Glibc
#endif

/// The FFmpeg build matrix: host detection, the supported target list, the
/// per-target configure flags and the SwiftPM triple each target provides.
enum Targets {
  static let supported = [
    "macos-arm64", "macos-x86_64", "linux-aarch64", "linux-x86_64",
    "windows-arm64", "windows-x86_64", "android-arm64", "android-x86_64",
    "ios-arm64", "ios-arm64-simulator", "ios-x86_64-simulator",
  ]

  /// Maps the host OS and architecture onto a supported target name.
  static func host() -> String {
    let arm = machine() == "arm64" || machine() == "aarch64"
    #if os(macOS)
      return arm ? "macos-arm64" : "macos-x86_64"
    #elseif os(Windows)
      return arm ? "windows-arm64" : "windows-x86_64"
    #else
      return arm ? "linux-aarch64" : "linux-x86_64"
    #endif
  }

  /// The `--arch` applies to every target except the two Apple ones, which
  /// take a clang `-target` triple instead.
  static func architecture(of name: String) -> String {
    name.contains("arm64") || name.contains("aarch64") ? "aarch64" : "x86_64"
  }

  /// Cross-compilation and toolchain flags for `name`, appended after the
  /// target-independent configure options.
  static func options(
    for name: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> [String] {
    let arch = architecture(of: name)
    var options = ["--arch=\(arch)"]
    if name.hasPrefix("ios-") {
      let sdk = name.hasSuffix("simulator") ? "iphonesimulator" : "iphoneos"
      let sysroot = try Shell.output(
        ["xcrun", "--sdk", sdk, "--show-sdk-path"], environment: environment)
      let triple =
        (arch == "aarch64" ? "arm64" : arch) + "-apple-ios16.0"
        + (sdk.hasSuffix("simulator") ? "-simulator" : "")
      options += [
        "--target-os=darwin", "--enable-cross-compile", "--cc=clang",
        "--sysroot=\(sysroot)", "--extra-cflags=-target \(triple)",
        "--extra-ldflags=-target \(triple)", "--disable-programs",
      ]
    } else if name.hasPrefix("android-") {
      guard let home = environment["ANDROID_NDK_HOME"], !home.isEmpty else {
        throw ToolError.message("Android builds require ANDROID_NDK_HOME for the NDK toolchain")
      }
      #if os(macOS)
        let tag = "darwin-x86_64"
      #else
        let tag = "linux-x86_64"
      #endif
      let tools = URL(fileURLWithPath: home)
        .appendingPathComponent("toolchains/llvm/prebuilt")
        .appendingPathComponent(tag)
        .appendingPathComponent("bin")
      let triple = arch == "aarch64" ? "aarch64-linux-android" : "x86_64-linux-android"
      options += [
        "--target-os=android", "--enable-cross-compile",
        "--cc=\(tools.appendingPathComponent(triple + "28-clang").path)",
        "--ar=\(tools.appendingPathComponent("llvm-ar").path)",
        "--ranlib=\(tools.appendingPathComponent("llvm-ranlib").path)",
        "--disable-programs",
      ]
    } else if name.hasPrefix("windows-") {
      options += [
        "--target-os=win32", "--toolchain=msvc", "--cc=cl", "--ar=lib", "--disable-x86asm",
      ]
    } else if name.hasPrefix("macos-") {
      let flags = "\(arch == "aarch64" ? "arm64" : arch) -mmacosx-version-min=13.0"
      options += [
        "--target-os=darwin", "--cc=clang",
        "--extra-cflags=-arch \(flags)", "--extra-ldflags=-arch \(flags)",
      ]
    } else {
      options += ["--target-os=linux", "--disable-x86asm"]
      if name != host() {
        guard let compiler = environment["GUAVA_FFMPEG_CC"], !compiler.isEmpty else {
          throw ToolError.message(
            "Linux cross builds require GUAVA_FFMPEG_CC for the target compiler")
        }
        options += ["--enable-cross-compile", "--cc=\(compiler)"]
      }
    }
    return options
  }

  /// The SwiftPM-supported triple for `name`.
  static func triple(_ name: String) -> String {
    if name.hasPrefix("ios-") {
      let device = name.replacingOccurrences(of: "ios-", with: "")
        .replacingOccurrences(of: "-simulator", with: "")
      return device + "-apple-ios" + (name.hasSuffix("simulator") ? "-simulator" : "")
    }
    let arch = name.hasSuffix("arm64") || name.hasSuffix("aarch64") ? "aarch64" : "x86_64"
    if name.hasPrefix("macos-") {
      return (arch == "aarch64" ? "arm64" : arch) + "-apple-macosx"
    }
    let suffix =
      name.hasPrefix("windows-")
      ? "unknown-windows-msvc"
      : name.hasPrefix("android-") ? "unknown-linux-android" : "unknown-linux-gnu"
    return arch + "-" + suffix
  }

  /// `uname -m`, or `PROCESSOR_ARCHITECTURE` on Windows, lowercased.
  private static func machine() -> String {
    #if os(Windows)
      return (ProcessInfo.processInfo.environment["PROCESSOR_ARCHITECTURE"] ?? "").lowercased()
    #else
      var info = utsname()
      guard uname(&info) == 0 else { return "" }
      let machine = withUnsafeBytes(of: info.machine) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
      }
      return machine.lowercased()
    #endif
  }
}
