internal import Foundation
internal import ToolSupport

/// Stages the pinned Wasmtime runtime and drives the portable plugin probe.
///
/// Replaces `Engine/third-party/wasmtime/stage.py` and the
/// `Engine/Validation/Plugins/{prepare,verify}.py` helpers. The first token of
/// `arguments` selects the operation; the remaining tokens are its flags.
public enum PluginStaging {
  public static func run(_ arguments: [String]) throws {
    guard let operation = arguments.first else {
      throw ToolError.message("Missing operation; expected stage, prepare, or verify")
    }
    let flags = Array(arguments.dropFirst())
    switch operation {
    case "stage": try StageOperation.run(flags)
    case "prepare": try PrepareOperation.run(flags)
    case "verify": try VerifyOperation.run(flags)
    case "-h", "--help": print(usage)
    default:
      throw ToolError.message(
        "Unknown operation '\(operation)'; expected stage, prepare, or verify")
    }
  }

  static let usage = """
    guava task plugins -- <operation> [options]

      stage    Stage a pinned Wasmtime runtime independently of the graphics dependencies
      prepare  Build shared Component fixtures using the same Wasmtime C API as production
      verify   Run the portable Component execution/fuel gate against a staged native runtime

    stage   [--platform NAME] [--check] [--vendor PATH] [--cache PATH]
    prepare --probe PATH --output PATH
    verify  --probe PATH
    """
}
