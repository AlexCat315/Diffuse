@testable import EditorCore
import Foundation
import PluginRuntime
import Testing

/// Swift Support's `tasks` entry point in its real Component, fed recorded
/// SwiftPM output: the plugin decides the commands and reads the output.
@Suite("Swift package tasks")
struct SwiftPackageTaskTests {
    private let plugin: StepPlugin

    init() throws {
        let provider = try #require(TaskProvider.bundled.first { $0.contribution.id == "swiftpm" })
        let client = PluginHostProcessClient(executableURL: try #require(EditorPluginHostLocator.resolve()))
        plugin = StepPlugin(provider: provider.step,
                            tool: ContributionTool(executable: URL(fileURLWithPath: "/usr/bin/false"), environment: [:]),
                            workspace: FileManager.default.temporaryDirectory, client: client)
    }

    private func result<T: Decodable>(_ operation: [String: Any], next: String, output: String, as type: T.Type) async throws -> T {
        guard case let .result(data) = try await plugin.perform(operation, resuming: (next, Data(output.utf8))) else {
            throw StepError.protocolViolation("not a JSON result")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test("each task names its SwiftPM command; builds and tests stream")
    func commands() throws {
        func step(_ operation: [String: Any]) throws -> [String: Any] {
            let request = String(decoding: try JSONSerialization.data(withJSONObject: operation), as: UTF8.self)
            return try #require(try JSONSerialization.jsonObject(with: plugin.invoke(request, stdout: "")) as? [String: Any])
        }
        #expect(try step(["op": "build"])["run"] as? [String] == ["build"])
        #expect(try step(["op": "build"])["stream"] as? Bool == true)
        #expect(try step(["op": "test", "filter": "App.Suite/test()"])["run"] as? [String]
                == ["test", "--filter", #"(^|\.)App\.Suite/test(\(\))?$"#])
        #expect(try step(["op": "run", "target": "Tool"])["run"] as? [String] == ["run", "Tool"])
        #expect(try step(["op": "run", "target": "--help"])["error"] != nil)
        #expect(try step(["op": "describe"])["stream"] == nil)
    }

    @Test("describe lists runnable products and the package's sections")
    func describe() async throws {
        let json = #"""
        warning: something
        {"name": "Demo",
         "products": [{"name": "Tool", "targets": ["Tool"], "type": {"executable": null}},
                      {"name": "Core", "targets": ["Core"], "type": {"library": ["automatic"]}}],
         "targets": [{"name": "Core", "type": "library", "path": "Sources/Core"},
                     {"name": "CoreTests", "type": "test", "path": "Tests/CoreTests"}],
         "dependencies": [{"identity": "swift-argument-parser", "type": "sourceControl", "url": "https://github.com/apple/swift-argument-parser"}]}
        """#
        let description = try await result(["op": "describe"], next: "describe", output: json, as: TaskProjectDescription.self)
        #expect(description.name == "Demo")
        #expect(description.runnables == ["Tool"])
        #expect(description.sections.map(\.title) == ["Products", "Targets", "Dependencies"])
        #expect(description.sections[0].items.map(\.detail) == ["executable", "library"])
    }

    @Test("build output becomes problems, once each")
    func problems() async throws {
        let output = """
        Building for debugging...
        /p/Sources/Core/A.swift:3:9: error: cannot find 'x' in scope
        /p/Sources/Core/A.swift:3:9: error: cannot find 'x' in scope
        Sources/Core/B.swift:10:1: \u{1B}[1;35mwarning: \u{1B}[1;39mvariable 'y' was never used\u{1B}[0;0m
        note: not a location
        error: fatalError
        """
        let report = try await result(["op": "build"], next: "report", output: output, as: TaskReport.self)
        #expect(report.problems.map(\.file) == ["/p/Sources/Core/A.swift", "Sources/Core/B.swift"])
        #expect(report.problems.map(\.severity) == [.error, .warning])
        #expect(report.problems[1].line == 10)
        #expect(report.problems[1].message == "variable 'y' was never used")
    }

    @Test("XCTest and Swift Testing results resolve to the index's identifiers")
    func testResults() async throws {
        let known = ["MathTests/testAdd()", "Arithmetic/sums()", "Arithmetic/differs()"]
        let output = """
        Test Case '-[CoreTests.MathTests testAdd]' started.
        Test Case '-[CoreTests.MathTests testAdd]' passed (0.001 seconds).
        ◇ Test sums() started.
        ✔ Test sums() passed after 0.001 seconds.
        ✘ Test differs() recorded an issue at Suite.swift:9:5: Expectation failed: 1 == 2
        ✘ Test differs() failed after 0.002 seconds with 1 issue.
        """
        let report = try await result(["op": "test", "known": known], next: "report", output: output, as: TaskReport.self)
        let tests = try #require(report.tests)
        #expect(tests.map(\.id) == known)
        #expect(tests.map(\.status) == [.passed, .passed, .failed])
        #expect(tests[2].message == "Expectation failed: 1 == 2")
    }
}
