internal import ToolSupport

/// Rejects new oversized Swift types and initializers; reports existing debt.
///
/// This is a structural guard, not a replacement for Swift's parser or code
/// review. It ignores comments, strings, computed/static properties, and nested
/// function bodies when counting a type's stored properties.
public enum Maintainability {
  public static func run(_ arguments: [String]) throws {
    var report = false
    for argument in arguments {
      switch argument {
      case "--report":
        report = true
      case "-h", "--help":
        Terminal.info(usage)
        return
      default:
        throw ToolError.message("unrecognized arguments: \(argument)")
      }
    }

    let baseline = try Baseline.allowances()
    let result = Inventory.evaluate(try Inventory.declarations(), baseline: baseline)
    if report { Terminal.info(result.debt.joined(separator: "\n")) }
    guard result.violations.isEmpty else {
      for violation in result.violations { Terminal.info(violation) }
      throw ToolError.message(
        "Split the declaration by responsibility; do not raise the baseline to silence this check.")
    }
    Terminal.info(
      "Swift maintainability check passed; \(result.debt.count) existing over-limit metrics cannot grow."
    )
  }

  static var usage: String {
    """
    usage: guava task maintainability -- [-h] [--report]

    Reject new oversized Swift types and initializers; report existing debt.
    This is a structural guard, not a replacement for Swift's parser or code
    review. It ignores comments, strings, computed/static properties, and
    nested function bodies when counting a type's stored properties.

    options:
      -h, --help  show this help message and exit
      --report    also list existing oversized declarations
    """
  }
}
