internal import Foundation
internal import ToolSupport

/// Runs a command with its combined output written to a log file and echoed to
/// this process's standard output, mirroring `command 2>&1 | tee log`.
///
/// `Shell` only offers capture-or-inherit, so the port keeps its own launcher
/// rather than widening the shared tool.
enum Tee {
  static func run(_ arguments: [String], environment: [String: String], log: URL) throws {
    guard let command = arguments.first, !command.isEmpty else {
      throw ToolError.message("Empty command")
    }
    Terminal.info("$ " + arguments.joined(separator: " "))
    let executable = try Shell.require(command, environment: environment)
    let process = Process()
    process.executableURL = executable
    process.arguments = Array(arguments.dropFirst())
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try Fs.write(data, to: log)
    FileHandle.standardOutput.write(data)
    guard process.terminationStatus == 0 else {
      throw ToolError.message("\(command) exited with status \(process.terminationStatus)")
    }
  }
}
