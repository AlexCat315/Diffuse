internal import Foundation
internal import ToolSupport

/// Canonicalizes a manifest path the way `Path(...).resolve()` did: absolute,
/// free of `.`/`..` components and with symlinks resolved.
func canonicalPath(_ path: String, relativeTo base: URL) -> URL {
  let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
  return url.standardizedFileURL.resolvingSymlinksInPath()
}

/// One `swift package dump-package` result, narrowed to the fields the boundary
/// checks assert on.
struct DumpPackage {
  /// A declared target, with its dependencies split by manifest shape.
  struct Target {
    let name: String
    let dependencyCount: Int
    let byName: Set<String>
    let products: Set<String>

    init(_ object: [String: Any]) throws {
      guard let name = object["name"] as? String else {
        throw ToolError.message("A target entry in the dumped package manifest has no name")
      }
      let dependencies = object["dependencies"] as? [Any] ?? []
      self.name = name
      self.dependencyCount = dependencies.count
      self.byName = Set(dependencies.compactMap { Self.value($0, "byName") })
      self.products = Set(dependencies.compactMap { Self.value($0, "product") })
    }

    /// `item["byName"][0]` / `item["product"][0]`, which always carry the value.
    private static func value(_ dependency: Any, _ key: String) -> String? {
      guard let dependency = dependency as? [String: Any] else { return nil }
      return (dependency[key] as? [Any])?.first as? String
    }
  }

  let directory: URL
  let name: String
  let productNames: Set<String>
  let targetCount: Int
  /// Local (file system) dependencies, resolved against the checkout root.
  let localDependencies: Set<URL>
  private let targets: [String: Target]

  init(directory: URL, root: URL, json: [String: Any]) throws {
    guard let name = json["name"] as? String else {
      throw ToolError.message(
        "\(directory.path) did not dump a package name; expected `swift package dump-package` JSON")
    }
    self.directory = directory
    self.name = name
    self.productNames = Set(
      (json["products"] as? [Any] ?? [])
        .compactMap { ($0 as? [String: Any])?["name"] as? String })
    let entries = json["targets"] as? [Any] ?? []
    self.targetCount = entries.count
    self.targets = try entries.reduce(into: [String: Target]()) { targets, entry in
      guard let object = entry as? [String: Any] else { return }
      let target = try Target(object)
      targets[target.name] = target
    }
    var dependencies: Set<URL> = []
    for entry in json["dependencies"] as? [Any] ?? [] {
      guard let object = entry as? [String: Any],
        let fileSystem = object["fileSystem"] as? [Any],
        let location = fileSystem.first as? [String: Any],
        let path = location["path"] as? String
      else { continue }
      dependencies.insert(canonicalPath(path, relativeTo: root))
    }
    self.localDependencies = dependencies
  }

  func target(named name: String) throws -> Target {
    guard let target = targets[name] else {
      throw ToolError.message("Package \(self.name) declares no target named \(name)")
    }
    return target
  }
}

/// Runs `swift package dump-package` for a package in the checkout. The Android
/// override variables are stripped from the inherited environment and applied
/// only by the checks that configure an application.
struct ManifestLoader {
  static let androidOverrides = ["GUAVA_ANDROID_UI_PACKAGE", "GUAVA_ANDROID_GAME_PACKAGE"]

  private let root: URL
  private let executable: String
  private let environment: [String: String]
  private var cache: [String: DumpPackage] = [:]

  init(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
    var environment = environment
    for key in Self.androidOverrides { environment.removeValue(forKey: key) }
    self.root = root
    self.environment = environment
    self.executable = environment["GUAVA_SWIFT_EXECUTABLE"] ?? "swift"
  }

  mutating func manifest(_ path: String, overrides: [String: String] = [:]) throws -> DumpPackage {
    let directory = root.appendingPathComponent(path).standardizedFileURL
    let key =
      ([directory.path] + overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
      .joined(separator: "\u{0}")
    if let cached = cache[key] { return cached }
    var environment = self.environment
    for (name, value) in overrides { environment[name] = value }
    let output = try Shell.output(
      [executable, "package", "--package-path", directory.path, "dump-package"],
      environment: environment)
    let package = try DumpPackage(
      directory: directory, root: root, json: try Self.decode(output, path: path))
    cache[key] = package
    return package
  }

  private static func decode(_ output: String, path: String) throws -> [String: Any] {
    if let json = object(in: Data(output.utf8)) { return json }
    // Progress and diagnostics share the captured stream, so fall back to the
    // outermost JSON object when the output is not pure JSON.
    if let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
      let json = object(in: Data(output[start...end].utf8))
    {
      return json
    }
    throw ToolError.message("swift package dump-package for \(path) did not produce JSON")
  }

  private static func object(in data: Data) -> [String: Any]? {
    guard let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return value as? [String: Any]
  }
}
