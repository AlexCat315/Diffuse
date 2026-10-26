internal import Foundation
private import ToolSupport

/// `build-fonts` — builds the pinned, unmodified FreeType/HarfBuzz submodules
/// for Swift's WASI SDK. Replaces `CoveUI/Browser/build_fonts.py`.
enum BuildFontsOperation {
  static func run(_ arguments: [String]) throws {
    var parser = FlagParser(arguments, valued: [])
    try parser.parse()
    if parser.flags.contains("--help") {
      Terminal.info(Browser.usage)
      return
    }
    if let unexpected = parser.positionals.first {
      throw ToolError.message("unrecognized arguments: \(unexpected)")
    }
    try buildFonts()
  }

  private static let here = Browser.sdkRoot.appendingPathComponent("Browser")
  private static let root = here.deletingLastPathComponent()
  private static let build = here.appendingPathComponent(".build/fonts")
  private static let vendor = here.appendingPathComponent(".build/font-vendor")

  static func buildFonts() throws {
    try verifyFontChecksums()
    let sysroot = try sysroot()
    let compiler = try compilerBinDirectory()
    func tool(_ name: String) throws -> URL {
      let candidate = compiler.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
      guard let resolved = Shell.executable(name) else {
        throw ToolError.message("Missing \(name): install a Swift/LLVM toolchain with Wasm support")
      }
      return resolved
    }
    let clang = try tool("clang")
    let clangxx = try tool("clang++")
    let ar = try tool("llvm-ar")
    let ranlib = try tool("llvm-ranlib")

    let toolchain = build.appendingPathComponent("wasi.cmake")
    try Fs.directory(build)
    try Fs.write(
      toolchainText(clang: clang, clangxx: clangxx, ar: ar, ranlib: ranlib, sysroot: sysroot),
      to: toolchain)

    let install = build.appendingPathComponent("install")
    let common = [
      "-G", "Ninja", "-DCMAKE_TOOLCHAIN_FILE=\(toolchain.path)",
      "-DCMAKE_C_FLAGS=-mllvm -wasm-enable-sjlj",
      "-DCMAKE_CXX_FLAGS=-mllvm -wasm-enable-sjlj -fno-exceptions -fno-threadsafe-statics -DHB_NO_MT",
      "-DCMAKE_INSTALL_PREFIX=\(install.path)", "-DCMAKE_BUILD_TYPE=Release",
      "-DBUILD_SHARED_LIBS=OFF",
    ]
    let sources = root.appendingPathComponent("third-party")
    let parallel = ProcessInfo.processInfo.environment["CMAKE_BUILD_PARALLEL_LEVEL"] ?? "4"
    for (name, featureOptions) in libraries(install: install) {
      guard
        FileManager.default.fileExists(
          atPath: sources.appendingPathComponent(name).appendingPathComponent("CMakeLists.txt").path
        )
      else {
        throw ToolError.message(
          "Missing \(name): run git submodule update --init CoveUI/third-party/\(name)")
      }
      let directory = build.appendingPathComponent(name)
      try Shell.inherit(
        [
          "cmake", "-S", sources.appendingPathComponent(name).path,
          "-B", directory.path,
        ] + common + featureOptions)
      try Shell.inherit(["cmake", "--build", directory.path, "--parallel", parallel])
      try Shell.inherit(["cmake", "--install", directory.path])
    }

    for bundle in bundles { try stage(bundle) }
  }

  // MARK: - Font checksums

  private static func verifyFontChecksums() throws {
    let fonts = root.appendingPathComponent("Text/Fonts")
    let manifest = try JSON.parse(try Fs.text(fonts.appendingPathComponent("manifest.json")))
    for item in manifest["fonts"]?.array ?? [] {
      guard let file = item["file"]?.string else { continue }
      let data = try Fs.read(fonts.appendingPathComponent(file))
      if data.count != item["bytes"]?.int || SHA256.hex(data) != item["sha256"]?.string {
        throw ToolError.message("Font checksum mismatch: \(file)")
      }
    }
  }

  // MARK: - Toolchain

  private static func sysroot() throws -> String {
    let sdk = ProcessInfo.processInfo.environment["COVE_WASM_SDK"] ?? "swift-6.4.1-RELEASE_wasm"
    let configuration = try Shell.output(["swift", "sdk", "configure", sdk, "--show-configuration"])
    for line in configuration.split(separator: "\n") where line.hasPrefix("sdkRootPath: ") {
      return String(line.dropFirst("sdkRootPath: ".count))
    }
    throw ToolError.message("swift sdk configure did not report sdkRootPath for \(sdk)")
  }

  /// On macOS `/usr/bin/swift` is an xcrun shim, so the real toolchain is
  /// derived from `swiftc -print-target-info`.
  private static func compilerBinDirectory() throws -> URL {
    let info = try JSON.parse(try Shell.output(["swiftc", "-print-target-info"]))
    guard let resource = info["paths"]?["runtimeResourcePath"]?.string else {
      throw ToolError.message("swiftc -print-target-info did not report runtimeResourcePath")
    }
    return URL(fileURLWithPath: resource).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("bin")
  }

  private static func toolchainText(clang: URL, clangxx: URL, ar: URL, ranlib: URL, sysroot: String)
    -> String
  {
    """
    set(CMAKE_SYSTEM_NAME Generic)
    set(CMAKE_SYSTEM_PROCESSOR wasm32)
    set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
    set(CMAKE_C_COMPILER "\(clang.path)")
    set(CMAKE_CXX_COMPILER "\(clangxx.path)")
    set(CMAKE_AR "\(ar.path)")
    set(CMAKE_RANLIB "\(ranlib.path)")
    set(CMAKE_C_COMPILER_TARGET wasm32-unknown-wasip1)
    set(CMAKE_CXX_COMPILER_TARGET wasm32-unknown-wasip1)
    set(CMAKE_SYSROOT "\(sysroot)")
    set(CMAKE_FIND_ROOT_PATH "\(sysroot)" "\(build.appendingPathComponent("install").path)")
    set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
    set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
    set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
    set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
    set(CMAKE_C_FLAGS_INIT "-mllvm -wasm-enable-sjlj")
    set(CMAKE_CXX_FLAGS_INIT "-mllvm -wasm-enable-sjlj -fno-exceptions -fno-threadsafe-statics -DHB_NO_MT")
    """ + "\n"
  }

  private static func libraries(install: URL) -> [(String, [String])] {
    let freetype = ["ZLIB", "BZIP2", "PNG", "HARFBUZZ", "BROTLI"].map { "-DFT_DISABLE_\($0)=ON" }
    let harfbuzz = [
      "-DCMAKE_PREFIX_PATH=\(install.path)", "-DHB_HAVE_FREETYPE=ON",
      "-DHAVE_SYS_MMAN_H=OFF", "-DHAVE_MMAP=OFF", "-DHAVE_MPROTECT=OFF",
      "-DHB_BUILD_SUBSET=OFF", "-DHB_BUILD_UTILS=OFF", "-DHB_BUILD_TESTS=OFF",
      "-DHB_HAVE_GLIB=OFF", "-DHB_HAVE_ICU=OFF", "-DHB_HAVE_GRAPHITE2=OFF",
      "-DHB_HAVE_CORETEXT=OFF",
    ]
    return [("freetype", freetype), ("harfbuzz", harfbuzz)]
  }

  // MARK: - Artifact bundles

  /// One SwiftPM static-library artifact bundle to publish.
  struct Bundle {
    var module: String
    var library: String
    var headers: String
    var version: String
  }

  private static let bundles = [
    Bundle(module: "CFreeType", library: "freetype", headers: "freetype2", version: "2.14.3"),
    Bundle(module: "CHarfBuzz", library: "harfbuzz", headers: "harfbuzz", version: "14.5.1"),
  ]

  private static func stage(_ bundleInfo: Bundle) throws {
    let bundle = vendor.appendingPathComponent("\(bundleInfo.module).artifactbundle")
    let variant = bundle.appendingPathComponent("wasm32-wasip1")
    try Fs.directory(variant.appendingPathComponent("lib"))
    try Fs.copyTree(
      build.appendingPathComponent("install/include/\(bundleInfo.headers)"),
      to: variant.appendingPathComponent("include"))
    try Fs.copy(
      build.appendingPathComponent("install/lib/lib\(bundleInfo.library).a"),
      to: variant.appendingPathComponent("lib/lib\(bundleInfo.library).a"))
    let templates = root.appendingPathComponent("third-party/cmake/templates")
    try Fs.copy(
      templates.appendingPathComponent("\(bundleInfo.module).h"),
      to: variant.appendingPathComponent("include/\(bundleInfo.module).h"))
    try Fs.copy(
      templates.appendingPathComponent("\(bundleInfo.module).modulemap"),
      to: variant.appendingPathComponent("include/module.modulemap"))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    var data = try encoder.encode(ArtifactBundle(bundleInfo: bundleInfo))
    data.append(0x0A)
    try Fs.write(data, to: bundle.appendingPathComponent("info.json"))
  }

  /// The SwiftPM `info.json` written for one artifact bundle.
  private struct ArtifactBundle: Encodable {
    var schemaVersion = "1.0"
    var artifacts: [String: Artifact]

    init(bundleInfo: Bundle) {
      artifacts = [bundleInfo.module: Artifact(bundleInfo: bundleInfo)]
    }
  }

  private struct Artifact: Encodable {
    var type = "staticLibrary"
    var version: String
    var variants: [Variant]

    init(bundleInfo: Bundle) {
      version = bundleInfo.version
      variants = [Variant(bundleInfo: bundleInfo)]
    }
  }

  private struct Variant: Encodable {
    var path: String
    var supportedTriples = ["wasm32-unknown-wasip1"]
    var staticLibraryMetadata: Metadata

    init(bundleInfo: Bundle) {
      path = "wasm32-wasip1/lib/lib\(bundleInfo.library).a"
      staticLibraryMetadata = Metadata()
    }
  }

  private struct Metadata: Encodable {
    var headerPaths = ["wasm32-wasip1/include"]
  }
}
