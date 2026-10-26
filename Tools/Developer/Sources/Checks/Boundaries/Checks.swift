internal import Foundation
internal import ToolSupport

/// Verifies ownership between the standalone SDK and Studio packages.
struct BoundaryChecks {
  private static let demoProducts: Set<String> = [
    "GuavaUIDemo", "PetDemo", "GalleryContent", "CounterExample", "GuavaUIApp",
  ]
  /// Scene, physics and render-backend products belong to Studio.
  private static let engineOnlyProducts: Set<String> = [
    "RenderBackend", "SceneRuntime", "CardBattleRuntime", "CinematicRenderer",
    "SequenceRuntime", "PerceptionRuntime", "SemanticPipeline", "EngineCore",
  ]
  /// Compose, window and workspace products belong to the SDK; the engine
  /// integrates with it only through the host boundary.
  private static let uiOnlyProducts: Set<String> = [
    "GuavaUI", "GuavaUICompose", "GuavaUIComposeCore", "GuavaUIWorkspace",
    "GuavaUIRuntime", "GuavaUIWebView", "PlatformShell",
  ]
  private static let supportedPlatforms: Set<String> = ["mac", "win", "linux", "android", "ios"]
  private static let success = """
    Module boundaries passed: production UI, workspace launcher, Android application/game/showcase, and application templates
    """

  private let root: URL
  private let sdkRoot: URL
  private let application = FileManager.default.temporaryDirectory.appendingPathComponent("guava-boundary-" + UUID().uuidString)
  private var loader: ManifestLoader

  init(
    root: URL = Repository.root, environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    let root = root.standardizedFileURL.resolvingSymlinksInPath()
    self.root = root
    self.sdkRoot = canonicalPath(environment["GUAVA_SDK_ROOT"] ?? "GuavaUI", relativeTo: root)
    self.loader = ManifestLoader(root: root, environment: environment)
  }

  mutating func perform() throws {
    defer { try? Fs.remove(application) }
    #if os(Windows)
    let command = sdkRoot.appendingPathComponent("guava.cmd")
    #else
    let command = sdkRoot.appendingPathComponent("guava")
    #endif
    try Shell.inherit([command.path, "create", "app", application.path, "--sdk-root", sdkRoot.path])
    let ui = try loader.manifest(at: sdkRoot)
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

    let portable = try loader.manifest(at: sdkRoot.appendingPathComponent("Portable"))
    for (name, package) in [("GuavaUI", ui), ("GuavaUI/Portable", portable)] {
      for dependency in package.localDependencies
      where dependency.path.lowercased().contains("examples") {
        throw ToolError.message(
          "\(name) must not depend on an examples package: \(dependency.path)")
      }
    }

    let core = try portable.target(named: "GuavaUIAgentCore")
    try require(
      core.dependencyCount == 1 && core.products == ["GuavaFileSystem"],
      "Agent skills may use GuavaFileSystem, but must not depend on UI or Engine domains")
    try require(
      !portable.localDependencies.contains(path("Engine")),
      "GuavaUI/Portable must not depend on Engine")
    try require(
      !ui.localDependencies.contains(path("Editor")),
      "GuavaUI must not depend on Editor")
    try require(
      ui.productNames.contains("GuavaUIAgent"),
      "GuavaUI must keep vending the GuavaUIAgent product")

    try checkSDKIndependence(ui)
    try checkEngineIndependence()

    let capability = try loader.manifest(at: path("Engine")).target(named: "CapabilityRuntime")
    try require(
      capability.products == ["GuavaUIAgentCore"],
      "CapabilityRuntime must depend on exactly the GuavaUIAgentCore product")

    let workspace = try loader.manifest(at: path("."))
    try require(
      workspace.localDependencies == [path("Editor")],
      "The workspace package must depend on Editor and nothing else")
    try require(
      workspace.targetCount == 1,
      "The workspace must not duplicate Editor's target graph")

    try checkAndroidApplications()
    try checkAppContent()
    try checkTooling()

    Terminal.info(Self.success)
  }

  /// The SDK owns UI and the shared native layer. It must never reach back into
  /// the Studio package, and a plain UI application must not be able to pull
  /// scene, physics or render-backend modules through it.
  private func checkSDKIndependence(_ ui: DumpPackage) throws {
    let engineOnly = ui.referencedProducts.intersection(Self.engineOnlyProducts)
    try require(
      engineOnly.isEmpty,
      "GuavaUI must not vend engine products: \(engineOnly.sorted().joined(separator: ", "))")
    let studioDependency = ui.localDependencies.first { dependency in
      ["Engine", "Editor", "Platforms/Android"].contains {
        dependency.path == root.appendingPathComponent($0).path
      }
    }
    try require(
      studioDependency == nil,
      "GuavaUI must not depend on a Studio package: \(studioDependency?.path ?? "")")
  }

  /// Scene and render modules live in Studio. They may consume the SDK's shared
  /// native layer, but never the Compose view tree or the window host.
  private mutating func checkEngineIndependence() throws {
    let engine = try loader.manifest(at: path("Engine"))
    let leaked = engine.referencedProducts.intersection(Self.uiOnlyProducts)
    try require(
      leaked.isEmpty,
      "Engine must not reach into the UI layer: \(leaked.sorted().joined(separator: ", "))")
  }

  /// The Android package is dumped once per application configuration: content
  /// (UI) from a starter package, a game package, and its own showcase graph.
  private mutating func checkAndroidApplications() throws {
    let starter = application.path
    let content = try loader.manifest(
      at: path("Platforms/Android"),
      overrides: ["GUAVA_ANDROID_UI_PACKAGE": starter])
    let forbidden: Set<URL> = [path("Editor"), sdkRoot.appendingPathComponent("Examples"), sdkRoot.appendingPathComponent("Examples/Counter")]
    let pulled = content.localDependencies.intersection(forbidden)
    try require(
      pulled.isEmpty,
      "An Android application built from the generated application must not depend on \(pulled.sorted { $0.path < $1.path }.map(\.path).joined(separator: ", "))"
    )

    let gameDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("guava-game-contract-\(UUID().uuidString)")
    try Fs.directory(gameDirectory)
    defer { try? Fs.remove(gameDirectory) }
    let game = try loader.manifest(
      at: path("Platforms/Android"),
      overrides: ["GUAVA_ANDROID_GAME_PACKAGE": gameDirectory.path])
    try require(
      game.localDependencies.contains(path("Editor")),
      "An Android game application must depend on Editor")
    try require(
      !game.localDependencies.contains(sdkRoot.appendingPathComponent("Examples")),
      "An Android game application must not depend on GuavaUI/Examples")

    let showcase = try loader.manifest(at: path("Platforms/Android"))
    try require(
      showcase.localDependencies.contains(sdkRoot.appendingPathComponent("Examples")),
      "The Android showcase must depend on GuavaUI/Examples")
    try require(
      !showcase.localDependencies.contains(path("Editor")),
      "The Android showcase must not depend on Editor")
  }

  /// The Studio example and SDK template present the UI module directly; both
  /// AppContent entry points must call the same factory.
  private func checkAppContent() throws {
    for file in [
      application.appendingPathComponent("Sources/AppContent/App.swift"),
      sdkRoot.appendingPathComponent("Tools/Guava/Sources/GuavaCLI/Templates/UI/Sources/AppContent/App.swift"),
    ] {
      let content = try text(file)
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

  /// The CLI ships with the SDK, owns no Android side copy, and the starter's
  /// configuration and resources describe those real package names.
  private mutating func checkTooling() throws {
    let developer = try loader.manifest(at: path("Tools/Developer"))
    try require(
      !developer.productNames.contains("guava-dev") && developer.productNames.contains("NativeBootstrap")
        && developer.productNames.contains("ProjectTasks"),
      "Studio project tasks must be libraries dispatched by the SDK")
    let example = application
    let tools = try loader.manifest(at: sdkRoot.appendingPathComponent("Tools/Guava"))
    try require(
      tools.productNames == ["guava"],
      "GuavaUI/Tools/Guava must vend exactly the guava product")
    try require(
      developer.localDependencies.isSubset(of: [sdkRoot.appendingPathComponent("Tools/Support"), sdkRoot.appendingPathComponent("System")]),
      "Repository tools must build independently of application and engine packages: "
        + developer.localDependencies.map(\.path).sorted().joined(separator: ", "))
    try require(
      tools.localDependencies == [
        sdkRoot.appendingPathComponent("Hosts/Android/Contract"), sdkRoot.appendingPathComponent("Portable"), sdkRoot.appendingPathComponent("Logging"),
        sdkRoot.appendingPathComponent("Tools/Support"),
        sdkRoot.appendingPathComponent("System"),
      ],
      "The shipped CLI must depend only on SDK packages: "
        + tools.localDependencies.map(\.path).sorted().joined(separator: ", "))
    try require(
      !FileManager.default.fileExists(
        atPath: root.appendingPathComponent("Platforms/Android/Tools").path),
      "Android must not own a separate developer CLI")
    try require(
      !FileManager.default.fileExists(atPath: example.appendingPathComponent("android.swift").path),
      "the generated application must not ship its own android.swift launcher")
    try require(
      !FileManager.default.fileExists(
        atPath: example.appendingPathComponent("guava-android.json").path),
      "the generated application must not ship a separate guava-android.json")
    try checkConfiguration(in: example)
    try require(
      !FileManager.default.fileExists(
        atPath: example.appendingPathComponent("Sources/DesktopApp").path),
      "the generated application must not ship a DesktopApp outside AppContent")

    let starter = try loader.manifest(at: application)
    try require(
      starter.productNames == ["AppContent"],
      "the generated application must vend exactly the AppContent product")
    let resources = try text(
      example.appendingPathComponent("Sources/AppContent/AppResources.swift"))
    try require(
      resources.contains("\(starter.name)_AppContent"),
      "Resource lookup must match the actual SwiftPM package and target")
  }

  private func checkConfiguration(in example: URL) throws {
    guard let configuration = Self.json(try text(example.appendingPathComponent("guava.json")))
    else {
      throw ToolError.message("the generated application/guava.json is not a JSON object")
    }
    let platforms = Set(
      (configuration["targets"] as? [String: Any])?["platforms"] as? [String] ?? [])
    try require(
      platforms == Self.supportedPlatforms,
      "guava.json must target \(Self.supportedPlatforms.sorted().joined(separator: ", "))")
    guard let sdkVersion = (configuration["toolchain"] as? [String: Any])?["sdkVersion"] as? String
    else {
      throw ToolError.message(
        "the generated application/guava.json must declare toolchain.sdkVersion")
    }
    try require(
      !sdkVersion.isEmpty,
      "guava.json toolchain.sdkVersion must name a released SDK version")
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
