package import Foundation

package struct ProcessOutput: Sendable {
  package let status: Int32
  package let stdout: Data
  package let stderr: Data

  package var stdoutText: String {
    String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  package var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Finite processes drain both streams and feed stdin concurrently. The deadline
/// covers process exit as well as IO, including children that close their pipes
/// before exiting. Callers decide whether a nonzero status is an error.
package enum ProcessRunner {
  package static func run(
    _ arguments: [String], at directory: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    input: Data? = nil, timeout: TimeInterval? = nil,
    mergeError: Bool = false
  ) throws -> ProcessOutput {
    guard let command = arguments.first else { throw ToolError.message("Empty command") }
    let process = Process()
    process.executableURL = try Shell.require(command, environment: environment)
    process.arguments = Array(arguments.dropFirst())
    process.currentDirectoryURL = directory
    process.environment = environment
    let stdout = Pipe()
    let stderr = mergeError ? stdout : Pipe()
    let stdin = input.map { _ in Pipe() }
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = stdin.map { $0 as Any } ?? FileHandle.nullDevice

    let completion = DispatchGroup()
    completion.enter()
    process.terminationHandler = { _ in completion.leave() }
    try process.run()
    let output = read(stdout, completion: completion)
    let errors = mergeError ? nil : read(stderr, completion: completion)
    if let stdin, let input {
      completion.enter()
      DispatchQueue.global().async {
        defer {
          try? stdin.fileHandleForWriting.close()
          completion.leave()
        }
        try? stdin.fileHandleForWriting.write(contentsOf: input)
      }
    }
    let deadline = timeout.map { DispatchTime.now() + $0 } ?? .distantFuture
    guard completion.wait(timeout: deadline) == .success else {
      ProcessSignal.kill(process)
      // A descendant may still own a pipe. Do not let its lifetime defeat
      // the caller's deadline after the direct child has been killed.
      _ = completion.wait(timeout: .now() + 2)
      throw ToolError.message("\(command) did not finish within \(timeout ?? 0)s")
    }
    return ProcessOutput(
      status: process.terminationStatus, stdout: output.get() ?? Data(),
      stderr: errors?.get() ?? Data())
  }

  private static func read(_ pipe: Pipe, completion: DispatchGroup) -> UncheckedBox<Data> {
    let result = UncheckedBox<Data>()
    completion.enter()
    DispatchQueue.global().async {
      result.set(pipe.fileHandleForReading.readDataToEndOfFile())
      try? pipe.fileHandleForReading.close()
      completion.leave()
    }
    return result
  }
}
