internal import Boundaries
internal import Foundation
internal import IOSSimulator
internal import IOSStaging
internal import Maintainability
internal import MediaStaging
internal import NativeBootstrap
internal import PluginStaging
internal import RegressionReport
internal import ShaderToolchain
internal import ToolSupport
internal import VulkanBootstrap

#if !os(Windows)
  private import AndroidValidation
  private import Browser
  private import RuntimeValidation
#endif

@main
enum GuavaDev {
  static func main() {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let verb = arguments.first, verb != "--help", verb != "-h" else {
      print(usage)
      return
    }
    arguments.removeFirst()
    do {
      try dispatch(verb, arguments)
    } catch {
      Terminal.fail(error)
    }
  }

  private static func dispatch(_ verb: String, _ arguments: [String]) throws {
    switch verb {
    case "dependencies": try DependencyUpdate.run(arguments)
    case "export-game": try AndroidExport.run(arguments)
    case "plugin-build":
      guard let first = arguments.first else { throw ToolError.message("Supply a plugin directory") }
      let options = Array(arguments.dropFirst())
      guard options.isEmpty || (options.count == 2 && options[0] == "--output") else { throw ToolError.message("Use ./guava studio plugin-build DIRECTORY [--output PACKAGE.guavaplugin]") }
      try PluginBuild(directory: URL(fileURLWithPath: first), root: Repository.root,
          output: options.last.map { URL(fileURLWithPath: $0) }).run()
    case "maintainability": try Maintainability.run(arguments)
    case "boundaries": try Boundaries.run(arguments)
    case "shader": try ShaderToolchain.run(arguments)
    case "vulkan": try VulkanBootstrap.run(arguments)
    case "media": try MediaStaging.run(arguments)
    case "plugins": try PluginStaging.run(arguments)
    case "native-bootstrap": try NativeBootstrap.run(arguments)
    case "ios-native": try IOSStaging.run(arguments)
    case "ios-simulator": try IOSSimulator.run(arguments)
    #if !os(Windows)
      case "validate": try RuntimeValidation.run(arguments)
      case "devtools": try DevToolsCommands.run(arguments)
      case "android": try AndroidValidation.run(arguments)
      case "browser": try Browser.run(arguments)
    #else
      case "validate", "devtools", "android", "browser":
        throw ToolError.message("\(verb) requires a macOS or Linux host")
    #endif
    case "gpu-regression": try RegressionReport.run(arguments)
    default: throw ToolError.message("Unknown command '\(verb)'; run guava-dev --help")
    }
  }

  static var usage: String {
    """
    guava-dev — repository tooling for the GuavaStudio checkout

      guava-dev export-game PROJECT --id ID     export an Android game
      guava-dev plugin-build DIRECTORY           build a Studio plugin
      guava-dev maintainability [--report]         reject oversized Swift types
      guava-dev boundaries                         validate package/product boundaries
      guava-dev shader <compile|rebuild|bootstrap-slang> …
      guava-dev vulkan bootstrap [--destination PATH]
      guava-dev media [--platform NAME] [--vendor PATH] [--check]
      guava-dev plugins <stage|prepare|verify> …
      guava-dev native-bootstrap [--force]         build Engine + GuavaUI native deps
      guava-dev dependencies update natsel        refresh Natsel main in all lockfiles
      guava-dev ios-native [--sdk S] [--arch A]    stage isolated iOS native deps
      guava-dev ios-simulator <udid|validate> …    pick a simulator and verify a built .app
      guava-dev validate <mcp-protocol|crystal-rush|agent-diagnostics|editor-loop> …
      guava-dev devtools <query-ui|input-ui|capture-ui|record-timings|session> …
      guava-dev android <validate|demo|gallery|game|logging> …
      guava-dev browser <verify|dev|verify-dev> …
      guava-dev gpu-regression <run|verify DIR>    run and verify GPU regression tests

    Every command runs against the checkout discovered from the current
    directory (or GUAVA_ROOT). Run a command with --help for its flags.
    """
  }
}
