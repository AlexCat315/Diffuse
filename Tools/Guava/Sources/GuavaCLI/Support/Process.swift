import GuavaLogging
import Foundation

enum ToolError: Error, LocalizedError {
    case invalid(String)
    case failed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .failed(let command, let status): return "\(command) exited with status \(status)"
        }
    }
}

enum Shell {
    static func executable(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if name.contains("/") || name.contains("\\") {
            let file = URL(fileURLWithPath: name)
            guard FileManager.default.isExecutableFile(atPath: file.path) else { throw ToolError.invalid("Executable not found: \(name)") }
            return file
        }
        #if os(Windows)
        let separator: Character = ";"
        let extensions = [""] + (environment["PATHEXT"] ?? ".EXE;.CMD;.BAT").split(separator: ";").map(String.init)
        #else
        let separator: Character = ":"
        let extensions = [""]
        #endif
        for directory in (environment["PATH"] ?? "").split(separator: separator) {
            for suffix in extensions {
                let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name + suffix)
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        throw ToolError.invalid("Executable not found on PATH: \(name)")
    }

    static func start(_ arguments: [String], at directory: URL? = nil,
                      environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Process {
        guard let command = arguments.first else { throw ToolError.invalid("Empty command") }
        let process = Process()
        process.executableURL = try executable(command, environment: environment)
        process.arguments = Array(arguments.dropFirst()); process.currentDirectoryURL = directory
        var childEnvironment = environment
        childEnvironment["GUAVA_LOG_RUN_ID"] = childEnvironment["GUAVA_LOG_RUN_ID"] ?? LogSystem.launch.runID
        process.environment = childEnvironment
        try process.run()
        return process
    }

    /// Passes arguments directly to the executable; never interprets a shell command.
    @discardableResult
    static func run(_ arguments: [String], at directory: URL? = nil,
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    capture: Bool = false, quiet: Bool = false) throws -> String {
        guard let command = arguments.first else { throw ToolError.invalid("Empty command") }
        let logger = LogSystem.logger("com.guava.cli.process")
        if !quiet { logger.debug("Starting command", metadata: ["command": "\(URL(fileURLWithPath: command).lastPathComponent)", "arguments": "\(arguments.count - 1)"]) }
        let process = Process()
        process.executableURL = try executable(command, environment: environment)
        process.arguments = Array(arguments.dropFirst())
        process.currentDirectoryURL = directory
        var childEnvironment = environment
        childEnvironment["GUAVA_LOG_RUN_ID"] = childEnvironment["GUAVA_LOG_RUN_ID"] ?? LogSystem.launch.runID
        process.environment = childEnvironment
        let output = ProcessStream(command: command, stream: "stdout", destination: capture ? nil : .standardOutput, collect: capture)
        let errors = ProcessStream(command: command, stream: "stderr", destination: .standardError)
        process.standardOutput = output.pipe; process.standardError = errors.pipe
        let started = ContinuousClock.now
        try process.run()
        output.start(pid: process.processIdentifier); errors.start(pid: process.processIdentifier)
        process.waitUntilExit()
        let data = output.finish(); _ = errors.finish()
        if !quiet { logger.debug("Command finished", metadata: ["command": "\(command)", "status": "\(process.terminationStatus)", "duration": "\(started.duration(to: .now))"]) }
        guard process.terminationStatus == 0 else { throw ToolError.failed(command, process.terminationStatus) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
