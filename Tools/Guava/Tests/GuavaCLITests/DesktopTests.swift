import Foundation
import Testing
@testable import GuavaCLI

@Test func desktopPackagingCopiesExecutableResourcesAndIdentity() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guava-package-test-" + UUID().uuidString)
    defer { try? Files.remove(directory) }
    let configuration = ProjectConfiguration(application: .init(id: "com.example.package", name: "Package Test"),
                                             toolchain: .init(enginePath: "/SDK"))
    try Files.json(configuration, to: directory.appendingPathComponent("guava.json"))
    try Files.text("// Package", to: directory.appendingPathComponent("Package.swift"))
    let binaries = directory.appendingPathComponent("binaries")
    try Files.text("executable", to: binaries.appendingPathComponent("DesktopApp"))
    try Files.text("welcome", to: binaries.appendingPathComponent("Content.bundle/Assets/welcome.txt"))
    let project = try AppProject(at: directory)
    let package = DesktopPackage(project: project, platform: .mac)
    let artifact = try package.assemble(binaries: binaries, configuration: .debug, output: nil)
    #expect(FileManager.default.fileExists(atPath: artifact.executable.path))
    #expect(FileManager.default.fileExists(atPath: artifact.directory.appendingPathComponent("Contents/Resources/Content.bundle/Assets/welcome.txt").path))
    let data = try Data(contentsOf: artifact.directory.appendingPathComponent("Contents/Info.plist"))
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    #expect(plist["CFBundleIdentifier"] as? String == configuration.application.id)
    #expect(plist["CFBundleDisplayName"] as? String == configuration.application.name)
    // Rebuilding an owned artifact replaces stale resources.
    try Files.text("old", to: artifact.directory.appendingPathComponent("Contents/Resources/stale.txt"))
    _ = try package.assemble(binaries: binaries, configuration: .debug, output: nil)
    #expect(!FileManager.default.fileExists(atPath: artifact.directory.appendingPathComponent("Contents/Resources/stale.txt").path))
    #expect(throws: (any Error).self) { try package.assemble(binaries: binaries, configuration: .debug, output: directory) }
}
