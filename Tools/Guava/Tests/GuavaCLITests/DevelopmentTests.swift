import Foundation
import Testing
import GuavaUIDevToolsProtocol
@testable import GuavaCLI

@Test func profileUsesOptimizationWithExplicitDiagnostics() throws {
    let request = try Arguments(["run", "App", "--android", "--profile", "--devtools", "--no-open"])
    #expect(request.configuration == .profile)
    #expect(request.configuration.swiftConfiguration == "release")
    #expect(request.configuration.swiftFlags == ["-Xswiftc", "-DGUAVA_PROFILE"])
    #expect(request.flags == [.devtools, .noOpen])
    #expect(throws: (any Error).self) { try Arguments(["run", "--release", "--devtools"]) }
    #expect(throws: (any Error).self) { try Arguments(["run", "--no-open"]) }
    #expect(throws: (any Error).self) { try Arguments(["build", "--devtools"]) }
}

@Test func sessionDiscoveryAndForwardingDoNotEnterAuthoredConfiguration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("guava-session-test-" + UUID().uuidString)
    defer { try? Files.remove(root) }
    let configuration = ProjectConfiguration(application: .init(id: "com.example.session", name: "Session"), toolchain: .init(enginePath: "/SDK"))
    try Files.json(configuration, to: root.appendingPathComponent("guava.json"))
    try Files.text("// Package", to: root.appendingPathComponent("Package.swift"))
    let original = try Data(contentsOf: root.appendingPathComponent("guava.json"))
    let project = try AppProject(at: root)
    let development = try DevelopmentSession(project: project, configuration: .profile, platform: .android)
    let environment = development.environment()
    #expect(environment["GUAVA_DEVTOOLS_PORT"] == "0")
    #expect(environment["GUAVA_DEVTOOLS_TOKEN"] == development.launch.token)
    let runtime = DevToolsDiscovery(id: development.launch.id, pid: 123, endpoint: "ws://127.0.0.1:1234/?token=secret")
    let managed = try development.publish(runtime, device: .init(adb: "/adb", serial: "device", forwardedPort: 5678))
    #expect(managed.endpoint == "ws://127.0.0.1:5678/?token=secret")
    #expect(managed.runtime == runtime)
    #expect(try Data(contentsOf: root.appendingPathComponent("guava.json")) == original)
    let record = try JSONDecoder().decode(ManagedSession.self, from: Data(contentsOf: development.directory.appendingPathComponent("session.json")))
    #expect(record.runtime == runtime && record.configuration == .profile)
    #expect(throws: (any Error).self) { try development.publish(.init(id: "wrong", pid: 123, endpoint: runtime.endpoint)) }
    development.remove()
    #expect(!FileManager.default.fileExists(atPath: development.directory.path))
}

@Test func versionsAreValidatedBeforePlatformBuilds() throws {
    var version = ApplicationVersion()
    version.name = "1.2"
    #expect(throws: (any Error).self) { try version.validate() }
    version.name = "1.2.3"; version.build = 0
    #expect(throws: (any Error).self) { try version.validate() }
    version.build = 7
    try version.validate()
}
