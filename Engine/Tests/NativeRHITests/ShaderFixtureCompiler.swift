import Foundation
import XCTest
@testable import NativeRHI

enum ShaderFixtures {
    static func compile(_ fixture: String, entry: String, stage: ShaderStage,
                        target: String, groups: [Int]? = nil, groupConstants: [Int]? = nil) throws -> ShaderArtifact {
        guard let compiler = ProcessInfo.processInfo.environment["SLANGC"] else {
            throw XCTSkip("Set SLANGC to Slang 2026.19 for shader integration tests")
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let source = try XCTUnwrap(Bundle.module.url(forResource: fixture, withExtension: "slang", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("shader.json")
        let log = directory.appendingPathComponent("compiler.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = try developerTool(root: root)
        process.arguments = ["shader", "compile", source.path,
            "--entry", entry, "--stage", stage.rawValue, "--target", target,
            "--slangc", compiler, "--output", output.path]
        if let groups { process.arguments! += ["--threadgroup-size"] + groups.map(String.init) }
        if let groupConstants { process.arguments! += ["--threadgroup-constants"] + groupConstants.map(String.init) }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RHIError.invalidArgument(try String(contentsOf: log, encoding: .utf8))
        }
        return try JSONDecoder().decode(ShaderArtifact.self, from: Data(contentsOf: output))
    }

    /// Locates the first-party `guava-dev` shader tool, building it on demand.
    private static func developerTool(root: URL) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["GUAVA_DEV"], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let swift = try resolveExecutable(environment["GUAVA_SWIFT_EXECUTABLE"] ?? "swift")
        let package = root.appendingPathComponent("Tools/Developer")
        let process = Process()
        process.executableURL = swift
        process.arguments = ["build", "--package-path", package.path, "--product", "guava-dev", "--show-bin-path"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RHIError.invalidArgument("Cannot build the guava-dev tool under \(package.path)")
        }
        let binPath = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        #if os(Windows)
        let name = "guava-dev.exe"
        #else
        let name = "guava-dev"
        #endif
        let tool = URL(fileURLWithPath: binPath).appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw RHIError.invalidArgument("guava-dev was not produced at \(tool.path)")
        }
        return tool
    }

    private static func resolveExecutable(_ name: String) throws -> URL {
        #if os(Windows)
        let separator: Character = ";"
        let extensions = [""] + (ProcessInfo.processInfo.environment["PATHEXT"] ?? ".EXE;.CMD;.BAT").split(separator: ";").map(String.init)
        #else
        let separator: Character = ":"
        let extensions = [""]
        #endif
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: separator) {
            for suffix in extensions {
                let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name + suffix)
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        throw RHIError.invalidArgument("Cannot find \(name) on PATH")
    }
}
