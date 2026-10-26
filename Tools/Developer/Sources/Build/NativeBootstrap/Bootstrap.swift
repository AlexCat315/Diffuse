internal import Foundation
internal import MediaStaging
internal import PluginStaging
internal import ToolSupport

/// The single `native-bootstrap` operation, mirroring `bootstrap.py` step by
/// step: environment, toolchain discovery, readiness gates, then cmake.
enum Bootstrap {
  static func run(_ arguments: [String]) throws {
    let force = arguments.contains("--force")
    let root = Repository.root
    let sdkRoot = ProcessInfo.processInfo.environment["GUAVA_SDK_ROOT"]
      .map { URL(fileURLWithPath: $0).standardizedFileURL }
      ?? root.appendingPathComponent("GuavaUI")

    // mimalloc must not redirect the CRT allocator while the graphics
    // libraries and their consumers are built.
    var environment = ProcessInfo.processInfo.environment
    environment["MIMALLOC_DISABLE_REDIRECT"] = "1"
    #if os(Windows)
      try WindowsBuildEnvironment.activate(&environment)
    #endif

    // Media is an independent dependency graph. Incremental desktop builds
    // should not rebuild all graphics libraries when only FFmpeg is missing.
    let mediaVendor = root.appendingPathComponent("Engine/Media/vendor")
    let mediaReady = MediaStaging.isReady(platform: MediaStaging.host(), vendor: mediaVendor)
    if force || !mediaReady {
      try MediaStaging.run([], environment: environment)
    }

    #if os(Windows)
    let sdkCommand = sdkRoot.appendingPathComponent("guava.cmd")
    #else
    let sdkCommand = sdkRoot.appendingPathComponent("guava")
    #endif
    try Shell.inherit([sdkCommand.path, "setup", "--sdk-root", sdkRoot.path], environment: environment)

    // ── Sentinels ────────────────────────────────────────────────────────

    let engineDone = root.appendingPathComponent("Engine/vendor/ocio_openexr.artifactbundle")
    let guavaUIDone = sdkRoot.appendingPathComponent("vendor/CFreeType.artifactbundle")
    let terminalDone = sdkRoot.appendingPathComponent("vendor/GhosttyVt.artifactbundle")
    var wasmtimeReady = true
    do { try PluginStaging.run(["stage", "--check"]) } catch { wasmtimeReady = false }
    if !wasmtimeReady {
      try PluginStaging.run(["stage"])
      wasmtimeReady = true
    }

    if !force,
      FileManager.default.fileExists(atPath: engineDone.path),
      FileManager.default.fileExists(atPath: guavaUIDone.path),
      FileManager.default.fileExists(atPath: terminalDone.path),
      wasmtimeReady
    {
      print("Native deps already built. Run `guava-dev native-bootstrap --force` to rebuild.")
      return
    }

    // ── cmake ────────────────────────────────────────────────────────────

    guard let cmake = Shell.executable("cmake", environment: environment) else {
      throw ToolError.message("cmake not found on PATH — install CMake 3.20+ first.")
    }

    // --force must invalidate ExternalProject configure/build/install stamps
    // too. Merely rerunning CMake can silently reuse libraries from an older
    // submodule.
    if force {
      for package in ["Engine"] {
        try Fs.remove(root.appendingPathComponent(package).appendingPathComponent("build/native"))
      }
    }

    // ── Engine ───────────────────────────────────────────────────────────

    let engineSource = root.appendingPathComponent("Engine/third-party")
    let engineBuild = root.appendingPathComponent("Engine/build/native")
    let installPrefix = FileManager.default.temporaryDirectory.appendingPathComponent(
      "guava-native-install")

    print("\n[ Engine ]")
    try Shell.inherit(
      [
        cmake.path, "-S", engineSource.path, "-B", engineBuild.path,
        "-DCMAKE_BUILD_TYPE=Release",
      ], environment: environment)
    // `--config Release` is required by multi-config generators (Visual
    // Studio): they ignore CMAKE_BUILD_TYPE and otherwise default to Debug,
    // which triggers MSVC's parallel PDB server (C1090) on the static-lib builds.
    // Harmless on single-config generators (Ninja/Make on macOS/Linux).
    try Shell.inherit(
      [cmake.path, "--build", engineBuild.path, "--parallel", "--config", "Release"],
      environment: environment)
    try Shell.inherit(
      [
        cmake.path, "--install", engineBuild.path, "--prefix", installPrefix.path,
        "--config", "Release",
      ], environment: environment)

    print("\nDone. Run: ./guava run Editor --mac")
  }
}
