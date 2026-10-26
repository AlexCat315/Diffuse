internal import Foundation
internal import ToolSupport
internal import CoveProcess

/// Device commands share the same finite-process IO and deadline behavior as
/// repository checks. Only file/inherited output needs a direct streaming path.
enum Command {
  static func run(_ arguments: [String], stdout: URL? = nil) throws {
    guard let stdout else { return try Shell.inherit(arguments) }
    guard let command = arguments.first else { throw ToolError.message("Empty command") }
    Terminal.info("$ " + arguments.joined(separator: " "))
    try Fs.directory(stdout.deletingLastPathComponent())
    FileManager.default.createFile(atPath: stdout.path, contents: nil)
    let handle = try FileHandle(forWritingTo: stdout)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = try Shell.require(command)
    process.arguments = Array(arguments.dropFirst())
    process.standardOutput = handle
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    try verify(arguments, status: process.terminationStatus)
  }

  static func output(_ arguments: [String], discardError: Bool = false) throws -> String {
    String(decoding: try capture(arguments, discardError: discardError).stdout, as: UTF8.self)
  }

  static func data(_ arguments: [String]) throws -> Data {
    try capture(arguments).stdout
  }

  static func attempt(_ arguments: [String], timeout: TimeInterval) throws -> ProcessOutput {
    try ToolSupport.ProcessRunner.run(arguments, timeout: timeout)
  }

  private static func capture(_ arguments: [String], discardError: Bool = false) throws
    -> ProcessOutput
  {
    let result = try ToolSupport.ProcessRunner.run(arguments)
    if !discardError { FileHandle.standardError.write(result.stderr) }
    try verify(arguments, status: result.status)
    return result
  }

  private static func verify(_ arguments: [String], status: Int32) throws {
    guard status == 0 else { throw ToolError.command(arguments.first ?? "", status) }
  }
}
