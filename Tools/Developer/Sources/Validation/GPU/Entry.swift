internal import Foundation
internal import ToolSupport

/// GPU regression reporting: runs the fixed rendering inventory and verifies
/// the xUnit/XCTest evidence produced by the current run.
///
/// Replaces `scripts/test-gpu-regression.sh` and
/// `scripts/verify-gpu-regression.py`. The first token of `arguments` selects
/// the operation; the remaining tokens are its arguments.
package enum RegressionReport {
  package static func run(_ arguments: [String]) throws {
    guard let operation = arguments.first else {
      throw ToolError.message("Missing operation; expected run or verify")
    }
    let flags = Array(arguments.dropFirst())
    switch operation {
    case "run": try Runner.run(flags)
    case "verify": try VerifyOperation.run(flags)
    case "-h", "--help": Terminal.info(usage)
    default: throw ToolError.message("Unknown operation '\(operation)'; expected run or verify")
    }
  }

  /// `verify <report-dir>` — there is no default directory; the report must
  /// name the run whose Swift Testing XML and XCTest logs are checked.
  enum VerifyOperation {
    static func run(_ arguments: [String]) throws {
      if arguments.contains("-h") || arguments.contains("--help") {
        Terminal.info(RegressionReport.usage)
        return
      }
      guard let path = arguments.first else {
        throw ToolError.message("Missing report directory; expected verify <report-dir>")
      }
      if arguments.count > 1 {
        throw ToolError.message("unrecognized arguments: \(arguments[1])")
      }
      try Verification.verify(reportDirectory: URL(fileURLWithPath: path).standardizedFileURL)
    }
  }

  static let usage = """
    cove-dev gpu-regression <operation> [options]

      run     Run the fixed GPU regression inventory in Engine and CoveUI, then verify it
      verify  Verify an existing report directory's Swift Testing XML and XCTest logs

    run
    verify <report-dir>

    run reads COVE_GPU_TEST_OUTPUT_DIR (default Engine/build/gpu-regression)
    and COVE_SWIFT_EXECUTABLE (default swift).
    """
}
