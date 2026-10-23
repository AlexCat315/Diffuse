internal import Foundation
internal import MediaStaging
internal import ToolSupport

/// Stages isolated iOS native dependencies without replacing desktop artifacts.
///
/// Replaces `scripts/bootstrap-ios.py`: it stages the pinned FFmpeg variant for
/// the requested iOS SDK/arch, then configures and builds the Engine and
/// GuavaUI third-party CMake graphs into `build/ios-*/` with an iOS sysroot.
package enum IOSStaging {
  static let usage = """
    guava-dev ios-native [--sdk iphoneos|iphonesimulator] [--arch arm64|x86_64] [--plugins|--no-plugins]

      --sdk      iOS SDK to target; defaults to iphonesimulator.
      --arch     Architecture to build; defaults to arm64. Devices require arm64.
      --plugins  Build the Wasmtime/Pulley runtime (requires a Rust target).
    """

  package static func run(_ arguments: [String]) throws {
    var sdk = "iphonesimulator"
    var arch = "arm64"
    var plugins = true
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "-h", "--help":
        Terminal.info(usage)
        return
      case "--sdk":
        sdk = try value(arguments, &index)
      case "--arch":
        arch = try value(arguments, &index)
      case "--plugins": plugins = true
      case "--no-plugins": plugins = false
      default: throw ToolError.message("unrecognized arguments: \(arguments[index])")
      }
      index += 1
    }
    guard ["iphoneos", "iphonesimulator"].contains(sdk) else {
      throw ToolError.message(
        "argument --sdk: invalid choice: '\(sdk)' (choose from 'iphoneos', 'iphonesimulator')")
    }
    guard ["arm64", "x86_64"].contains(arch) else {
      throw ToolError.message(
        "argument --arch: invalid choice: '\(arch)' (choose from 'arm64', 'x86_64')")
    }
    try stage(sdk: sdk, arch: arch, plugins: plugins)
  }

  /// Runs the same build for the SDK/arch selected by the iOS application build.
  private static func stage(sdk: String, arch: String, plugins: Bool) throws {
    #if !os(macOS)
      throw ToolError.message("iOS builds require macOS; devices require arm64")
    #else
      guard !(sdk == "iphoneos" && arch != "arm64") else {
        throw ToolError.message("iOS builds require macOS; devices require arm64")
      }
      let root = Repository.root
      let variant = "ios-\(arch)" + (sdk == "iphonesimulator" ? "-simulator" : "")
      let vendor = Repository.path("Engine/Media/vendor")
      if !MediaStaging.isReady(platform: variant, vendor: vendor) {
        try MediaStaging.run(["--platform", variant])
      }
      let sysroot = try Shell.output(["xcrun", "--sdk", sdk, "--show-sdk-path"])
      for package in ["Engine", "GuavaUI/Runtime", "GuavaUI"] {
        let build = root.appendingPathComponent("\(package)/build/\(variant)")
        var command = [
          "cmake", "-S", root.appendingPathComponent("\(package)/third-party").path,
          "-B", build.appendingPathComponent("native").path,
          "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_SYSTEM_NAME=iOS",
          "-DCMAKE_OSX_SYSROOT=\(sysroot)", "-DCMAKE_OSX_ARCHITECTURES=\(arch)",
          "-DCMAKE_OSX_DEPLOYMENT_TARGET=16.0",
          "-DGUAVA_VENDOR_DIR=\(build.appendingPathComponent("vendor").path)",
        ]
        var targets: [String]
        if package == "Engine" {
          command += [
            "-DGUAVA_STAGE_WASMTIME=" + (plugins ? "ON" : "OFF"),
          ]
          // The Engine package resolves ocio_openexr from the staged artifact
          // root, so iOS must build and stage the EXR stack like every other
          // native dependency; a missing bundle breaks package resolution.
          targets = ["stage_jolt", "stage_ocio_openexr"]
          if plugins { targets.append("stage_wasmtime") }
        } else if package == "GuavaUI/Runtime" {
          targets = ["stage_sdl3", "stage_image_decode"]
        } else {
          targets = ["stage_freetype", "stage_harfbuzz"]
        }
        try Shell.inherit(command)
        try Shell.inherit(
          [
            "cmake", "--build", build.appendingPathComponent("native").path,
            "--parallel", "4", "--target",
          ] + targets)
        try Shell.inherit([
          "cmake", "--install", build.appendingPathComponent("native").path,
          "--prefix", build.appendingPathComponent("install").path,
        ])
      }
    #endif
  }

  private static func value(_ arguments: [String], _ index: inout Int) throws -> String {
    index += 1
    guard index < arguments.count else {
      throw ToolError.message("missing value for \(arguments[index - 1])")
    }
    return arguments[index]
  }
}
