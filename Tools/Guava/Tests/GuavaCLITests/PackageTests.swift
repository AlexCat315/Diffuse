import Foundation
import Testing
@testable import GuavaCLI

@Test func plainPackageTestsUseNativeCacheAndPreserveFilterAndSerialExecution() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Swift package with spaces \(UUID())")
    defer { try? Files.remove(directory) }
    try Files.text("// Package", to: directory.appendingPathComponent("Package.swift"))
    let plan = try PackageTests(Arguments(["test", directory.path, "--filter", "ListRowTests", "--no-parallel", "--profile"]))
    #expect(plan.command.contains(directory.path))
    #expect(plan.command.contains("--no-parallel"))
    #expect(plan.command.suffix(3) == ["--filter", "ListRowTests", "--no-parallel"])
    #expect(!plan.command.contains("--scratch-path"))
    #expect(plan.command.contains("release") && plan.command.contains("-DGUAVA_PROFILE"))
    #expect(plan.environment["GUAVA_ENGINE_ROOT"].map { GuavaSDK.isSDK(URL(fileURLWithPath: $0)) } == true)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("guava.json").path))
}

@Test func applicationTestsKeepTheirOwnedCacheAndValidateAuthoredManifest() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? Files.remove(directory) }
    try Files.text("// Package", to: directory.appendingPathComponent("Package.swift"))
    let root = try GuavaSDK.locate(Arguments(["test"]))
    let configuration = ProjectConfiguration(application: .init(id: "com.example.tests", name: "Tests"),
                                             toolchain: .init(enginePath: root.path))
    try Files.json(configuration, to: directory.appendingPathComponent("guava.json"))
    let plan = try PackageTests(Arguments(["test", directory.path]))
    #expect(plan.command.suffix(2) == ["--scratch-path", directory.appendingPathComponent(".guava/build/swift").path])
    #expect(plan.helpers.isEmpty)
    var withHelper = configuration
    withHelper.targets.desktopHelpers = ["GuavaPluginHost"]
    try Files.json(withHelper, to: directory.appendingPathComponent("guava.json"))
    let helpers = try PackageTests(Arguments(["test", directory.path])).helpers
    #expect(helpers.count == 1 && helpers[0].suffix(4) == ["--scratch-path", directory.appendingPathComponent(".guava/build/swift").path,
                                                         "--product", "GuavaPluginHost"])
    try Files.text("{}", to: directory.appendingPathComponent("guava.json"))
    #expect(throws: (any Error).self) { try PackageTests(Arguments(["test", directory.path])) }
}

@Test func packageTestsRejectMissingPackagesAndMisplacedSerialFlag() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(throws: (any Error).self) { try PackageTests(Arguments(["test", directory.path])) }
    for args in [["run", "--no-parallel"], ["devtools", "--no-parallel"], ["test", "--no-parallel", "--no-parallel"]] {
        #expect(throws: (any Error).self) { try Arguments(args) }
    }
}
