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
    /// Passes arguments directly to the executable; never interprets a shell command.
    @discardableResult
    static func run(_ arguments: [String], at directory: URL? = nil,
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    capture: Bool = false) throws -> String {
        guard !arguments.isEmpty else { throw ToolError.invalid("Empty command") }
        print("+ " + arguments.joined(separator: " "))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let output = Pipe()
        if capture { process.standardOutput = output }
        try process.run()
        let data = capture ? output.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ToolError.failed(arguments[0], process.terminationStatus) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
