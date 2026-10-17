internal import Foundation
private import ToolSupport

#if canImport(Darwin)
  internal import Darwin
#elseif canImport(Glibc)
  internal import Glibc
#endif

/// Flushes standard output so a parent process reading the pipe observes
/// progress immediately, matching the reference scripts' `print(..., flush=True)`
/// that `verify-dev` relies on.
func flushOutput() {
  fflush(stdout)
}

/// The combined standard output and exit status of one finished child process.
/// It mirrors `subprocess.run(..., stdout=PIPE, stderr=STDOUT)` without the
/// failure-throwing behavior of `Shell`, so a development build can report its
/// own diagnostics.
struct CapturedCommand {
  var status: Int32
  var output: String
}

/// Runs a child to completion and captures its combined output.
func capture(
  _ executable: URL, _ arguments: [String], directory: URL? = nil,
  environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> CapturedCommand {
  let result = try ProcessRunner.run(
    [executable.path] + arguments, at: directory, environment: environment, mergeError: true)
  return CapturedCommand(
    status: result.status, output: String(decoding: result.stdout, as: UTF8.self))
}

func staticServer(directory: URL, port: Int = 0, backlog: Int = 32) throws -> HTTPServer {
  try HTTPServer(port: port, backlog: backlog) { request, response in
    StaticFiles.respond(request, response, directory: directory)
  }
}

enum BrowserExecutable {
  static func current() throws -> URL {
    if let url = Bundle.main.executableURL, FileManager.default.isExecutableFile(atPath: url.path) {
      return url
    }
    if let url = Shell.executable("guava-dev") { return url }
    throw ToolError.message("Cannot locate the guava-dev executable")
  }
}
