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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("scripts/compile-rhi-shader.py").path,
            source.path, "--entry", entry, "--stage", stage.rawValue, "--target", target,
            "--slangc", compiler, "--output", output.path]
        if let groups { process.arguments! += ["--threadgroup-size"] + groups.map(String.init) }
        if let groupConstants { process.arguments! += ["--threadgroup-constants"] + groupConstants.map(String.init) }
        #if os(Windows)
        let environment = ProcessInfo.processInfo.environment
        let paths = (environment["PATH"] ?? "").split(separator: ";").flatMap { directory in
            ["python3.exe","python.exe"].map { URL(fileURLWithPath: String(directory)).appendingPathComponent($0).path }
        }
        let python = try XCTUnwrap(environment["PYTHON"] ?? paths.first(where: FileManager.default.isExecutableFile(atPath:)))
        process.executableURL = URL(fileURLWithPath: python); process.arguments!.removeFirst()
        #endif
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RHIError.invalidArgument(try String(contentsOf: log, encoding: .utf8))
        }
        return try JSONDecoder().decode(ShaderArtifact.self, from: Data(contentsOf: output))
    }
}
