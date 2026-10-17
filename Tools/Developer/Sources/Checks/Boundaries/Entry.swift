private import ToolSupport

/// Validates application, platform and example dependency boundaries via SwiftPM.
/// The checks themselves live in `BoundaryChecks`; this is the CLI entry point.
package enum Boundaries {
  /// The former tool took no arguments; the parameter exists for the CLI contract.
  package static func run(_ arguments: [String]) throws {
    if arguments == ["--help"] || arguments == ["-h"] {
      Terminal.info("guava-dev boundaries — validate package, application and template boundaries")
      return
    }
    guard arguments.isEmpty else { throw ToolError.message("boundaries takes no arguments") }
    var checks = BoundaryChecks()
    try checks.perform()
  }
}
