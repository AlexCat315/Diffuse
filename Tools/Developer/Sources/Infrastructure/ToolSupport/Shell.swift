package import Foundation

/// Thin, explicit process launching. Arguments are always passed as a vector;
/// no tool in this package interprets a shell string.
package enum Shell {
  package static func executable(
    _ name: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    if name.contains("/") || name.contains("\\") {
      let file = URL(fileURLWithPath: name)
      return FileManager.default.isExecutableFile(atPath: file.path) ? file : nil
    }
    #if os(Windows)
      let separator: Character = ";"
      let extensions =
        [""] + (environment["PATHEXT"] ?? ".EXE;.CMD;.BAT").split(separator: ";").map(String.init)
    #else
      let separator: Character = ":"
      let extensions = [""]
    #endif
    for directory in (environment["PATH"] ?? "").split(separator: separator) {
      for suffix in extensions {
        let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(
          name + suffix)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
      }
    }
    return nil
  }

  package static func require(
    _ name: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> URL {
    guard let url = executable(name, environment: environment) else {
      throw ToolError.message("Required tool not found on PATH: \(name)")
    }
    return url
  }

  /// Runs to completion and returns trimmed standard output.
  @discardableResult
  package static func output(
    _ arguments: [String], at directory: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    echo: Bool = false
  ) throws -> String {
    try run(arguments, at: directory, environment: environment, capture: true, echo: echo)
  }

  /// Runs to completion, forwarding the child's standard streams to this tool.
  package static func inherit(
    _ arguments: [String], at directory: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    input: String? = nil
  ) throws {
    _ = try run(
      arguments, at: directory, environment: environment, capture: false, echo: true, input: input)
  }

  @discardableResult
  package static func run(
    _ arguments: [String], at directory: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    capture: Bool, echo: Bool, input: String? = nil
  ) throws -> String {
    guard let command = arguments.first, !command.isEmpty else {
      throw ToolError.message("Empty command")
    }
    if echo { print("$ " + arguments.joined(separator: " ")) }
    if capture {
      let result = try ProcessRunner.run(
        arguments, at: directory, environment: environment,
        input: input.map { Data($0.utf8) }, mergeError: true)
      guard result.status == 0 else {
        if !result.stdout.isEmpty { Terminal.error(result.stdoutText) }
        throw ToolError.command(command, result.status)
      }
      return result.stdoutText
    }
    let process = Process()
    process.executableURL = try require(command, environment: environment)
    process.arguments = Array(arguments.dropFirst())
    process.currentDirectoryURL = directory
    process.environment = environment
    let inputPipe = input.map { _ in Pipe() }
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    if let inputPipe {
      process.standardInput = inputPipe
    } else if input != nil {
      process.standardInput = FileHandle.standardInput
    }
    try process.run()
    if let inputPipe {
      let payload = Data((input ?? "").utf8)
      DispatchQueue.global().async {
        try? inputPipe.fileHandleForWriting.write(contentsOf: payload)
        try? inputPipe.fileHandleForWriting.close()
      }
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ToolError.command(command, process.terminationStatus)
    }
    return ""
  }
}
