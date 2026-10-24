internal import Foundation
internal import ToolSupport

/// Builds the pinned C API with the portable Pulley interpreter for iOS.
enum IOSRuntime {
  static let features = ["cranelift", "component-model", "pulley", "wat"]

  static func build(_ source: URL, _ target: String, _ cache: URL) throws -> URL {
    let buildRoot = cache.appendingPathComponent("ios-target").resolvingSymlinksInPath()
    var environment = ProcessInfo.processInfo.environment
    environment["CARGO_TARGET_DIR"] = buildRoot.path
    environment["IPHONEOS_DEPLOYMENT_TARGET"] = "26.0"
    try Shell.inherit(
      [
        "cargo", "build",
        "--manifest-path", source.appendingPathComponent("Cargo.toml").path,
        "--locked", "--package", "wasmtime-c-api",
        "--target", target, "--release",
        "--no-default-features",
        "--features", features.joined(separator: ","),
        "--jobs", "4",
      ], environment: environment)

    let installed = cache.appendingPathComponent(target + "-install")
    let headers = installed.appendingPathComponent("include")
    try copyMerging(source.appendingPathComponent("crates/c-api/include"), to: headers)
    try configure(
      headerTemplate: headers.appendingPathComponent("wasmtime/conf.h.in"),
      output: headers.appendingPathComponent("wasmtime/conf.h"))
    try Fs.remove(headers.appendingPathComponent("wasmtime/conf.h.in"))
    try Fs.directory(installed.appendingPathComponent("lib"))
    try Fs.copy(
      buildRoot.appendingPathComponent(target).appendingPathComponent("release/libwasmtime.a"),
      to: installed.appendingPathComponent("lib/libwasmtime.a"))
    try Fs.copy(
      source.appendingPathComponent("LICENSE"), to: installed.appendingPathComponent("LICENSE"))
    return installed
  }

  /// Rewrites the CMake header template into the `#define`/disabled form the
  /// C API expects for exactly the enabled features.
  private static func configure(headerTemplate: URL, output: URL) throws {
    let template = try Fs.text(headerTemplate)
    let enabled = Set(
      features.map {
        "WASMTIME_FEATURE_" + $0.uppercased().replacingOccurrences(of: "-", with: "_")
      })
    let expression = try NSRegularExpression(pattern: "#cmakedefine (\\w+)")
    let matches = expression.matches(
      in: template, range: NSRange(template.startIndex..., in: template))
    var result = ""
    var cursor = template.startIndex
    for match in matches {
      guard let full = Range(match.range, in: template),
        let name = Range(match.range(at: 1), in: template)
      else { continue }
      result += template[cursor..<full.lowerBound]
      let token = String(template[name])
      result += enabled.contains(token) ? "#define \(token)" : "/* \(token) disabled */"
      cursor = full.upperBound
    }
    result += template[cursor...]
    try Fs.write(result, to: output)
  }

  /// `copytree(..., dirs_exist_ok=True)`: merges into an existing directory.
  private static func copyMerging(_ source: URL, to destination: URL) throws {
    try Fs.directory(destination)
    for entry in try FileManager.default.contentsOfDirectory(
      at: source, includingPropertiesForKeys: [.isDirectoryKey])
    {
      let target = destination.appendingPathComponent(entry.lastPathComponent)
      let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      if isDirectory {
        try copyMerging(entry, to: target)
      } else {
        try Fs.copy(entry, to: target)
      }
    }
  }
}
