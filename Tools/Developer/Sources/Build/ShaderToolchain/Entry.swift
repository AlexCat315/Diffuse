internal import ToolSupport

/// Repository shader toolchain: one entry point that dispatches to the
/// `compile`, `rebuild`, and `bootstrap-slang` operations.
package enum ShaderToolchain {
  /// The first token selects the operation; the rest are that operation's flags.
  package static func run(_ arguments: [String]) throws {
    guard let operation = arguments.first else {
      throw ToolError.message("Expected an operation: compile, rebuild, or bootstrap-slang")
    }
    let rest = Array(arguments.dropFirst())
    switch operation {
    case "--help", "-h":
      Terminal.info("guava-dev shader <compile|rebuild|bootstrap-slang> [options]")
    case "compile": try CompileCommand.run(rest)
    case "rebuild": try RebuildCommand.run(rest)
    case "bootstrap-slang": try BootstrapCommand.run(rest)
    default: throw ToolError.message("Unknown shader toolchain operation '\(operation)'")
    }
  }
}
