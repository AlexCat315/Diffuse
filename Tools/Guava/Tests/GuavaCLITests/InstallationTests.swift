import Foundation
import Testing
@testable import GuavaCLI

@Test func sdkSelectionIsSeparateFromApplicationConfiguration() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? Files.remove(base) }
    let sdk = base.appendingPathComponent("SDK with spaces")
    try Files.text("// engine", to: sdk.appendingPathComponent("Engine/Package.swift"))
    try Files.text("// ui", to: sdk.appendingPathComponent("GuavaUI/Package.swift"))
    let store = SDKStore(directory: base.appendingPathComponent("user"))
    #expect(store.selected == nil)
    try store.use(sdk)
    #expect(store.selected?.path == sdk.path)
    #expect(throws: (any Error).self) { try store.use(base) }
    #expect(store.selected?.path == sdk.path)
}

@Test func ordinaryApplicationLauncherIsGeneratedWithoutAuthoredEntryPoint() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? Files.remove(base) }
    let arguments = try Arguments(["create", "app", base.path, "--platforms", "mac"])
    try CreateApplication.run(arguments, root: URL(fileURLWithPath: "/SDK with spaces"))
    let project = try AppProject(at: base)
    #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Sources/DesktopApp").path))
    let authored = try Data(contentsOf: base.appendingPathComponent("Package.swift"))
    let generated = try DesktopLauncher(project: project, root: URL(fileURLWithPath: "/SDK with spaces")).prepare()
    #expect(generated.path.hasPrefix(project.buildDirectory.path))
    #expect(project.desktopProduct == "Application")
    #expect(try String(contentsOf: generated.appendingPathComponent("Sources/Application/main.swift"), encoding: .utf8).contains("makeApplicationContent()"))
    #expect(try Data(contentsOf: base.appendingPathComponent("Package.swift")) == authored)
}

@Test func installationCommandsRequireExplicitRevisionAndTargetSelection() throws {
    let install = try Arguments(["sdk", "install", "https://example.com/sdk.git", "--revision", "v0.1.0"])
    #expect(install.operation == .sdkInstall)
    #expect(install.value(.revision) == "v0.1.0")
    #expect(try Arguments(["setup", "--android"]).platform == .android)
    #expect(throws: (any Error).self) { try Arguments(["sdk", "list", "unexpected"]) }
}
