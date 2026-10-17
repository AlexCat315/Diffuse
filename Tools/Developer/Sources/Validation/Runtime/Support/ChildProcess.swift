internal import Foundation
internal import ToolSupport

#if canImport(Darwin)
  internal import Darwin
#elseif canImport(Glibc)
  internal import Glibc
#endif

/// A long-running child process spoke to over newline-delimited JSON, used for
/// the stdio MCP server and for the editors the validations launch.
final class ChildProcess {
  enum Stream {
    case inherit
    case discard
    case pipe
    case file(FileHandle)
  }

  private let process = Process()
  private let stdinPipe: Pipe?
  private let stdoutPipe: Pipe?
  private var buffer = Data()

  init(
    _ executable: URL, _ arguments: [String] = [],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    stdin: Stream = .inherit, stdout: Stream = .inherit, stderr: Stream = .inherit
  ) throws {
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment

    var input: Pipe?
    switch stdin {
    case .pipe:
      let pipe = Pipe()
      input = pipe
      process.standardInput = pipe
    case .discard: process.standardInput = FileHandle.nullDevice
    case .file(let handle): process.standardInput = handle
    case .inherit: process.standardInput = FileHandle.standardInput
    }

    var output: Pipe?
    if case .pipe = stdout {
      let pipe = Pipe()
      output = pipe
      process.standardOutput = pipe
    } else {
      process.standardOutput = ChildProcess.handle(stdout)
    }

    process.standardError = ChildProcess.handle(stderr)
    stdinPipe = input
    stdoutPipe = output
    try process.run()
  }

  private static func handle(_ stream: Stream) -> FileHandle? {
    switch stream {
    case .inherit: return nil
    case .discard: return FileHandle.nullDevice
    case .file(let handle): return handle
    case .pipe: return nil
    }
  }

  var isRunning: Bool { process.isRunning }
  var processIdentifier: Int32 { process.processIdentifier }

  func sendLine(_ object: [String: Any]) throws {
    try send(try JSON.data(object) + Data([0x0A]))
  }

  func send(_ data: Data) throws {
    guard let stdinPipe else {
      throw ToolError.message("Child process standard input is not piped")
    }
    try stdinPipe.fileHandleForWriting.write(contentsOf: data)
  }

  func closeInput() {
    try? stdinPipe?.fileHandleForWriting.close()
  }

  /// Next JSON line, or `nil` when nothing arrived within `timeout`.
  func readLine(timeout: TimeInterval) throws -> [String: Any]? {
    guard let stdoutPipe else {
      throw ToolError.message("Child process standard output is not piped")
    }
    if let line = try takeLine() { return line }
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      let remaining = deadline.timeIntervalSinceNow
      if remaining <= 0 { return nil }
      if try POSIXIO.readable([stdoutPipe.fileHandleForReading.fileDescriptor], timeout: remaining)
        .isEmpty
      {
        continue
      }
      guard let chunk = POSIXIO.read(stdoutPipe.fileHandleForReading.fileDescriptor, upTo: 65536)
      else {
        throw ToolError.message("Child process exited before responding")
      }
      buffer.append(chunk)
      if let line = try takeLine() { return line }
    }
  }

  /// Blocks until exit, returning the status or `nil` on timeout.
  @discardableResult
  func wait(timeout: TimeInterval) -> Int32? {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning {
      if Date() >= deadline { return nil }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return process.terminationStatus
  }

  func terminate() {
    if process.isRunning { process.terminate() }
  }

  func kill() {
    ProcessSignal.kill(process)
  }

  /// Terminate with a grace period, escalating to a hard kill, then reap.
  func stop() {
    guard process.isRunning else { return }
    if wait(timeout: 0) != nil { return }
    process.terminate()
    if wait(timeout: 5) == nil {
      kill()
      _ = wait(timeout: 5)
    }
  }

  private func takeLine() throws -> [String: Any]? {
    guard let index = buffer.firstIndex(of: 0x0A) else { return nil }
    let line = buffer.subdata(in: buffer.startIndex..<index)
    buffer.removeSubrange(buffer.startIndex...index)
    return try JSON.parseObject(line)
  }
}
