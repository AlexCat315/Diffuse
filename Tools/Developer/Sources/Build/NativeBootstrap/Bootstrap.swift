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

    // mimalloc must not redirect the CRT allocator while the graphics
    // libraries and their consumers are built.
    var environment = ProcessInfo.processInfo.environment
    environment["MIMALLOC_DISABLE_REDIRECT"] = "1"
    #if os(Windows)
      try activateVisualStudio(&environment)
    #endif

    // Media is an independent dependency graph. Incremental desktop builds
    // should not rebuild all graphics libraries when only FFmpeg is missing.
    let mediaVendor = root.appendingPathComponent("Engine/Media/vendor")
    let mediaReady = MediaStaging.isReady(platform: MediaStaging.host(), vendor: mediaVendor)
    if force || !mediaReady {
      try MediaStaging.run([], environment: environment)
    }

    // ── Sentinels ────────────────────────────────────────────────────────

    let engineDone = root.appendingPathComponent("Engine/vendor/SDL3.artifactbundle")
    let guavaUIDone = root.appendingPathComponent("GuavaUI/vendor/CFreeType.artifactbundle")
    let terminalDone = root.appendingPathComponent("GuavaUI/vendor/GhosttyVt.artifactbundle")
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
      for package in ["Engine", "GuavaUI"] {
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
    // which both mismatches the Release-only Jolt config defines and
    // triggers MSVC's parallel PDB server (C1090) on the static-lib builds.
    // Harmless on single-config generators (Ninja/Make on macOS/Linux).
    try Shell.inherit(
      [cmake.path, "--build", engineBuild.path, "--parallel", "--config", "Release"],
      environment: environment)
    // stage_image_decode is not in the default ALL target, so the blanket
    // build above skips it. stage_sdl3 (ALL) already pulled SDL3-static in,
    // but build it explicitly too so SDL3-static exists before `--install`
    // copies it into the artifactbundle. Both are top-level custom targets,
    // so `--target` resolves on every generator (the Visual Studio generator
    // cannot build the subdirectory `SDL3-static` target directly). Mirrors
    // .github/workflows/ci-engine.yml.
    try Shell.inherit(
      [
        cmake.path, "--build", engineBuild.path, "--parallel", "--config", "Release",
        "--target", "stage_sdl3",
      ], environment: environment)
    try Shell.inherit(
      [
        cmake.path, "--build", engineBuild.path, "--parallel", "--config", "Release",
        "--target", "stage_image_decode",
      ], environment: environment)
    try Shell.inherit(
      [
        cmake.path, "--install", engineBuild.path, "--prefix", installPrefix.path,
        "--config", "Release",
      ], environment: environment)

    // ── GuavaUI ──────────────────────────────────────────────────────────

    let guavaSource = root.appendingPathComponent("GuavaUI/third-party")
    let guavaBuild = root.appendingPathComponent("GuavaUI/build/native")

    print("\n[ GuavaUI ]")
    try Shell.inherit(
      [
        cmake.path, "-S", guavaSource.path, "-B", guavaBuild.path,
        "-DCMAKE_BUILD_TYPE=Release",
      ], environment: environment)
    try Shell.inherit(
      [cmake.path, "--build", guavaBuild.path, "--parallel", "--config", "Release"],
      environment: environment)
    try Shell.inherit(
      [
        cmake.path, "--install", guavaBuild.path, "--prefix", installPrefix.path,
        "--config", "Release",
      ], environment: environment)

    print("\nDone. Run: swift build --package-path Editor")
  }
}
