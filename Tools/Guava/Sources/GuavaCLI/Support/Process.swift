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
        process.environment = environment
        try process.run()
        return process
    }

    /// Passes arguments directly to the executable; never interprets a shell command.
    @discardableResult
    static func run(_ arguments: [String], at directory: URL? = nil,
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    capture: Bool = false, quiet: Bool = false) throws -> String {
        guard let command = arguments.first else { throw ToolError.invalid("Empty command") }
        let display = arguments.count > 16
            ? Array(arguments.prefix(10)) + ["… (\(arguments.count - 10) more arguments)"] : arguments
        if !quiet { print("+ " + display.joined(separator: " ")) }
        let process = Process()
        process.executableURL = try executable(command, environment: environment)
        process.arguments = Array(arguments.dropFirst())
        process.currentDirectoryURL = directory
        process.environment = environment
        let output = Pipe()
        if capture { process.standardOutput = output }
        try process.run()
        let data = capture ? output.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ToolError.failed(command, process.terminationStatus) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
