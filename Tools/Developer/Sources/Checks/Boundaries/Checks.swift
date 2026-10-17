internal import Foundation
internal import ToolSupport

/// Every assertion from the former `scripts/check-module-boundaries.py`, in the
/// same order, so the first reported failure is the one a maintainer saw there.
struct BoundaryChecks {
  private static let demoProducts: Set<String> = [
    "GuavaUIDemo", "PetDemo", "GalleryContent", "CounterExample", "GuavaUIApp",
  ]
  private static let supportedPlatforms: Set<String> = ["mac", "win", "linux", "android", "ios"]
  private static let success = """
    Module boundaries passed: production UI, workspace launcher, Android application/game/showcase, and application templates
    """

  private let root: URL
  private var loader: ManifestLoader

  init(
    root: URL = Repository.root, environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    let root = root.standardizedFileURL.resolvingSymlinksInPath()
    self.root = root
    self.loader = ManifestLoader(root: root, environment: environment)
  }

  mutating func perform() throws {
    let ui = try loader.manifest("GuavaUI")
    try require(
      ui.productNames.contains("GuavaUI"),
      "GuavaUI must remain a production product")
    let leaked = ui.productNames.intersection(Self.demoProducts)
    try require(
      leaked.isEmpty,
      "GuavaUI must not vend demo or example products: \(leaked.sorted().joined(separator: ", "))")
    let launcher = try ui.target(named: "GuavaUI")
    try require(
      !launcher.byName.contains("GuavaUIWorkspace"),
      "GuavaUI must not depend on the GuavaUIWorkspace launcher target")

    let portable = try loader.manifest("GuavaUI/Portable")
    for (name, package) in [("GuavaUI", ui), ("GuavaUI/Portable", portable)] {
      for dependency in package.localDependencies
      where dependency.path.lowercased().contains("examples") {
        throw ToolError.message(
          "\(name) must not depend on an examples package: \(dependency.path)")
      }
    }

    let core = try portable.target(named: "GuavaUIAgentCore")
    try require(
      core.dependencyCount == 0,
      "Generic agent contracts, MCP and skills must not depend on UI or Engine domains")
    try require(
      !portable.localDependencies.contains(path("Engine")),
      "GuavaUI/Portable must not depend on Engine")
    try require(
      !ui.localDependencies.contains(path("Editor")),
      "GuavaUI must not depend on Editor")
    try require(
      ui.productNames.contains("GuavaUIAgent"),
      "GuavaUI must keep vending the GuavaUIAgent product")

    let capability = try loader.manifest("Engine").target(named: "CapabilityRuntime")
    try require(
      capability.products == ["GuavaUIAgentCore"],
      "CapabilityRuntime must depend on exactly the GuavaUIAgentCore product")

    let workspace = try loader.manifest(".")
    try require(
      workspace.localDependencies == [path("Editor")],
      "The workspace package must depend on Editor and nothing else")
    try require(
      workspace.targetCount == 1,
      "The workspace must not duplicate Editor's target graph")

    try checkAndroidApplications()
    try checkAppContent()
    try checkTemplateParity()
    try checkTooling()

    Terminal.info(Self.success)
  }

  /// The Android package is dumped once per application configuration: content
  /// (UI) from a starter package, a game package, and its own showcase graph.
  private mutating func checkAndroidApplications() throws {
    let starter = root.appendingPathComponent("examples/GuavaUIStarter").path
    let content = try loader.manifest(
      "Platforms/Android",
      overrides: ["GUAVA_ANDROID_UI_PACKAGE": starter])
    let forbidden: Set<URL> = [path("Editor"), path("GuavaUI/Examples"), path("examples/Counter")]
    let pulled = content.localDependencies.intersection(forbidden)
    try require(
      pulled.isEmpty,
      "An Android application built from examples/GuavaUIStarter must not depend on \(pulled.sorted { $0.path < $1.path }.map(\.path).joined(separator: ", "))"
    )

    let gameDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("guava-game-contract-\(UUID().uuidString)")
    try Fs.directory(gameDirectory)
    defer { try? Fs.remove(gameDirectory) }
    let game = try loader.manifest(
      "Platforms/Android",
      overrides: ["GUAVA_ANDROID_GAME_PACKAGE": gameDirectory.path])
    try require(
      game.localDependencies.contains(path("Editor")),
      "An Android game application must depend on Editor")
    try require(
      !game.localDependencies.contains(path("GuavaUI/Examples")),
      "An Android game application must not depend on GuavaUI/Examples")

    let showcase = try loader.manifest("Platforms/Android")
    try require(
      showcase.localDependencies.contains(path("GuavaUI/Examples")),
      "The Android showcase must depend on GuavaUI/Examples")
    try require(
      !showcase.localDependencies.contains(path("Editor")),
      "The Android showcase must not depend on Editor")
  }

  /// The starter and its template must present the UI module directly, and both
  /// AppContent entry points must call the same factory.
  private func checkAppContent() throws {
    for base in [
      "examples/GuavaUIStarter/Sources", "Tools/Guava/Sources/GuavaCLI/Templates/UI/Sources",
    ] {
      let file = "\(base)/AppContent/App.swift"
      let content = try text(root.appendingPathComponent(file))
      try require(
        content.contains("import GuavaUI\n"),
        "\(file) must import GuavaUI")
      try require(
        !content.contains("import NativeRHI") && !content.contains("import GuavaUIRuntime"),
        "\(file) must not import NativeRHI or GuavaUIRuntime")
      try require(
        content.contains("makeApplicationContent()"),
        "\(file) must call makeApplicationContent()")
    }
  }

  /// Every template file must match the starter byte for byte, with the `.in`
  /// suffix stripped from the destination name.
  private func checkTemplateParity() throws {
    let template = root.appendingPathComponent("Tools/Guava/Sources/GuavaCLI/Templates/UI")
    let example = root.appendingPathComponent("examples/GuavaUIStarter")
    for source in try Fs.files(in: template) {
      let relative = Fs.relative(source, to: template)
      let destination = example.appendingPathComponent(
        relative.hasSuffix(".in") ? String(relative.dropLast(3)) : relative)
      guard FileManager.default.fileExists(atPath: destination.path) else {
        throw ToolError.message("Starter drifted from its template: \(relative)")
      }
      let expected = try Fs.read(source)
      let actual = try Fs.read(destination)
      try require(actual == expected, "Starter drifted from its template: \(relative)")
    }
  }

  /// The developer CLI lives in Tools/Guava, owns no Android side copy, and the
  /// starter's configuration and resources describe those real package names.
  private mutating func checkTooling() throws {
    let developer = try loader.manifest("Tools/Developer")
    try require(
      developer.productNames == ["guava-dev"],
      "Tools/Developer must vend only the guava-dev executable")
    try require(
      developer.localDependencies.isEmpty,
      "Repository tools must build independently of application and engine packages")
    let example = root.appendingPathComponent("examples/GuavaUIStarter")
    let tools = try loader.manifest("Tools/Guava")
    try require(
      tools.productNames == ["guava"],
      "Tools/Guava must vend exactly the guava product")
    let expected = Set([
      path("Platforms/Android/Contract"), path("GuavaUI/Portable"), path("Engine/Logging"),
    ])
    try require(
      tools.localDependencies == expected,
      "Tools/Guava must depend on Android/Contract, GuavaUI/Portable and Engine/Logging")
    try require(
      !FileManager.default.fileExists(
        atPath: root.appendingPathComponent("Platforms/Android/Tools").path),
      "Android must not own a separate developer CLI")
    try require(
      !FileManager.default.fileExists(atPath: example.appendingPathComponent("android.swift").path),
      "examples/GuavaUIStarter must not ship its own android.swift launcher")
    try require(
      !FileManager.default.fileExists(
        atPath: example.appendingPathComponent("guava-android.json").path),
      "examples/GuavaUIStarter must not ship a separate guava-android.json")
    try checkConfiguration(in: example)
    try require(
      !FileManager.default.fileExists(
        atPath: example.appendingPathComponent("Sources/DesktopApp").path),
      "examples/GuavaUIStarter must not ship a DesktopApp outside its template")

    let starter = try loader.manifest("examples/GuavaUIStarter")
    try require(
      starter.productNames == ["AppContent"],
      "examples/GuavaUIStarter must vend exactly the AppContent product")
    let resources = try text(
      example.appendingPathComponent("Sources/AppContent/AppResources.swift"))
    try require(
      resources.contains("\(starter.name)_AppContent"),
      "Resource lookup must match the actual SwiftPM package and target")
  }

  private func checkConfiguration(in example: URL) throws {
    guard let configuration = Self.json(try text(example.appendingPathComponent("guava.json")))
    else {
      throw ToolError.message("examples/GuavaUIStarter/guava.json is not a JSON object")
    }
    let platforms = Set(
      (configuration["targets"] as? [String: Any])?["platforms"] as? [String] ?? [])
    try require(
      platforms == Self.supportedPlatforms,
      "guava.json must target \(Self.supportedPlatforms.sorted().joined(separator: ", "))")
    guard let enginePath = (configuration["toolchain"] as? [String: Any])?["enginePath"] as? String
    else {
      throw ToolError.message(
        "examples/GuavaUIStarter/guava.json must declare toolchain.enginePath")
    }
    try require(
      canonicalPath(enginePath, relativeTo: example) == root,
      "guava.json toolchain.enginePath must resolve to the checkout root")
  }

  private func path(_ relative: String) -> URL {
    canonicalPath(relative, relativeTo: root)
  }

  /// `Path.read_text()` applies universal newline translation; keep the port faithful.
  private func text(_ url: URL) throws -> String {
    let content = try Fs.text(url)
    return content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
      of: "\r", with: "\n")
  }

  private static func json(_ content: String) -> [String: Any]? {
    guard let value = try? JSONSerialization.jsonObject(with: Data(content.utf8)) else {
      return nil
    }
    return value as? [String: Any]
  }

  private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    guard condition else { throw ToolError.message(message()) }
  }
}
