internal import Foundation
internal import ToolSupport
internal import GuavaProcess

/// The validation boundary supplies a deadline and inspects nonzero statuses.
enum Subprocess {
  @discardableResult
  static func run(
    _ executable: URL, arguments: [String] = [],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    input: Data? = nil, timeout: TimeInterval
  ) throws -> ProcessOutput {
    try ToolSupport.ProcessRunner.run(
      [executable.path] + arguments, environment: environment, input: input, timeout: timeout)
  }

  @discardableResult
  static func run(
    _ command: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
    timeout: TimeInterval
  ) throws -> ProcessOutput {
    try ToolSupport.ProcessRunner.run(command, environment: environment, timeout: timeout)
  }
}
