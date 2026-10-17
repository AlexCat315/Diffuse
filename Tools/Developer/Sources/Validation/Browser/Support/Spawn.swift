internal import Foundation
private import ToolSupport

#if canImport(Glibc)
  private import Glibc
#endif

#if canImport(Darwin)
  internal import Darwin

  /// Copies a Swift string into a C string the `posix_spawn` vector can own.
  private func spawnDuplicate(_ value: String) -> UnsafeMutablePointer<CChar>? {
    value.withCString { strdup($0) }
  }

  /// A child process whose combined standard output is captured for inspection,
  /// and which can optionally lead its own process group so a development server
  /// and the builds it spawns are terminated together.
  final class SpawnedProcess: @unchecked Sendable {
    let pid: pid_t
    private let leadsSession: Bool
    private let captured = Locked("")
    private let statusLock = NSLock()
    private var status: Int32?

    init(
      executable: URL,
      arguments: [String],
      directory: URL? = nil,
      environment: [String: String] = ProcessInfo.processInfo.environment,
      newSession: Bool = false
    ) throws {
      var descriptors: [Int32] = [0, 0]
      guard pipe(&descriptors) == 0 else {
        throw ToolError.message("Cannot create a pipe for \(executable.path)")
      }
      let readEnd = descriptors[0]
      let writeEnd = descriptors[1]

      var actions: posix_spawn_file_actions_t?
      posix_spawn_file_actions_init(&actions)
      posix_spawn_file_actions_adddup2(&actions, writeEnd, STDOUT_FILENO)
      posix_spawn_file_actions_adddup2(&actions, writeEnd, STDERR_FILENO)
      posix_spawn_file_actions_addclose(&actions, readEnd)
      posix_spawn_file_actions_addclose(&actions, writeEnd)
      if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory.path) }

      var attributes: posix_spawnattr_t?
      posix_spawnattr_init(&attributes)
      if newSession { posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)) }

      var argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map(spawnDuplicate)
      argv.append(nil)
      let variables = environment.map { "\($0.key)=\($0.value)" }.sorted()
      var envp: [UnsafeMutablePointer<CChar>?] = variables.map(spawnDuplicate)
      envp.append(nil)
      defer {
        for pointer in argv { free(pointer) }
        for pointer in envp { free(pointer) }
      }

      var child: pid_t = 0
      let result: Int32 = argv.withUnsafeMutableBufferPointer { argvBuffer in
        envp.withUnsafeMutableBufferPointer { envpBuffer in
          posix_spawn(
            &child, executable.path, &actions, &attributes, argvBuffer.baseAddress,
            envpBuffer.baseAddress)
        }
      }
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
      close(writeEnd)
      guard result == 0 else {
        close(readEnd)
        throw ToolError.message(
          "Cannot launch \(executable.path): \(String(cString: strerror(result)))")
      }
      self.pid = child
      self.leadsSession = newSession
      startReader(readEnd)
    }

    var output: String { captured.value }

    private func startReader(_ descriptor: Int32) {
      let thread = Thread { [self] in
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
          let count = read(descriptor, &bytes, bytes.count)
          if count <= 0 { break }
          let text = String(decoding: bytes[0..<count], as: UTF8.self)
          captured.mutate { $0 += text }
        }
        close(descriptor)
      }
      thread.stackSize = 1 << 20
      thread.start()
    }

    /// Returns the exit status once the process has exited, otherwise `nil`.
    func poll() -> Int32? {
      statusLock.lock()
      defer { statusLock.unlock() }
      if let status { return status }
      var value: Int32 = 0
      let result = waitpid(pid, &value, WNOHANG)
      guard result == pid else { return nil }
      let exit = (value & 0x7f) == 0 ? (value >> 8) & 0xff : 128 + (value & 0x7f)
      status = exit
      return exit
    }

    func wait(timeout: TimeInterval) -> Int32? {
      let deadline = Date(timeIntervalSinceNow: timeout)
      while true {
        if let status = poll() { return status }
        if Date() >= deadline { return nil }
        usleep(20_000)
      }
    }

    func signal(_ number: Int32) {
      if leadsSession {
        kill(-pid, number)
      } else {
        kill(pid, number)
      }
    }

    func terminate(timeout: TimeInterval = 5) {
      signal(SIGTERM)
      if wait(timeout: timeout) == nil {
        signal(SIGKILL)
        _ = wait(timeout: timeout)
      }
    }
  }

#elseif canImport(Glibc)

  internal import Glibc

  /// Foundation owns spawning and reaping on Linux. `setsid` isolates a dev
  /// server's build descendants so a failed verification can stop the whole run.
  final class SpawnedProcess: @unchecked Sendable {
    private let process = Process()
    private let captured = Locked("")
    private let reader = DispatchGroup()
    private let leadsSession: Bool
    var pid: pid_t { process.processIdentifier }
    var output: String { captured.value }

    init(
      executable: URL, arguments: [String], directory: URL? = nil,
      environment: [String: String] = ProcessInfo.processInfo.environment,
      newSession: Bool = false
    ) throws {
      leadsSession = newSession
      process.executableURL =
        newSession ? try Shell.require("setsid", environment: environment) : executable
      process.arguments = newSession ? [executable.path] + arguments : arguments
      process.currentDirectoryURL = directory
      process.environment = environment
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      try process.run()
      reader.enter()
      DispatchQueue.global().async { [self] in
        defer { reader.leave() }
        while true {
          let bytes = pipe.fileHandleForReading.availableData
          if bytes.isEmpty { return }
          captured.mutate { $0 += String(decoding: bytes, as: UTF8.self) }
        }
      }
    }

    func poll() -> Int32? { process.isRunning ? nil : process.terminationStatus }

    func wait(timeout: TimeInterval) -> Int32? {
      let deadline = Date(timeIntervalSinceNow: timeout)
      while process.isRunning {
        if Date() >= deadline { return nil }
        Thread.sleep(forTimeInterval: 0.02)
      }
      _ = reader.wait(timeout: .now() + 1)
      return process.terminationStatus
    }

    func signal(_ number: Int32) {
      guard process.isRunning else { return }
      Glibc.kill(leadsSession ? -pid : pid, number)
    }

    func terminate(timeout: TimeInterval = 5) {
      signal(SIGTERM)
      if wait(timeout: timeout) == nil {
        signal(SIGKILL)
        _ = wait(timeout: timeout)
      }
    }
  }
#endif
