import Foundation
import Testing
@testable import GuavaCLI

@Test func defaultProjectsIncludeSharedIOSContentAndXcodeHost() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? Files.remove(directory) }
    let arguments = try Arguments(["create", "app", directory.path])
    try CreateApplication.run(arguments, root: URL(fileURLWithPath: "/SDK"))
    let project = try AppProject(at: directory)
    #expect(project.configuration.targets.platforms.contains(.ios))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Platforms/iOS/Application.xcodeproj/project.pbxproj").path))
    let main = try String(contentsOf: directory.appendingPathComponent("Platforms/iOS/main.swift"), encoding: .utf8)
    #expect(main.contains("makeApplicationContent()"))
    #expect(!main.contains("UIApplicationDelegate"))
    let package = try String(contentsOf: directory.appendingPathComponent("Package.swift"), encoding: .utf8)
    #expect(package.contains(".iOS(.v16)"))
}

@Test func iosSigningAndSimulatorArgumentsAreDistinct() throws {
    let simulator = try Arguments(["run", "--ios", "--simulator", "UDID"])
    #expect(simulator.value(.simulator) == "UDID")
    let device = try Arguments(["build", "--ios", "--device", "DEVICE", "--team", "TEAM"])
    #expect(device.value(.team) == "TEAM")
    #expect(throws: (any Error).self) { try Arguments(["run", "--ios", "--device", "DEVICE", "--simulator", "UDID"]) }
    #expect(throws: (any Error).self) { try Arguments(["run", "--android", "--simulator", "UDID"]) }
}
