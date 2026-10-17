import Foundation
import Testing
@testable import GuavaCLI

#if !os(Windows)
@Test func developerTasksUseSelectedSDKRoot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SDK with spaces \(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("Tools/Developer")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data().write(to: package.appendingPathComponent("Package.swift"))
    let swift = root.appendingPathComponent("swift-tool")
    try """
    #!/bin/sh
    printf '%s\\n' "$GUAVA_ROOT" "$PWD" > "$GUAVA_TOOL_INVOCATION"
    """.write(to: swift, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
    let invocation = root.appendingPathComponent("invocation.txt")
    var environment = ProcessInfo.processInfo.environment
    environment["GUAVA_SWIFT_EXECUTABLE"] = swift.path
    environment["GUAVA_ROOT"] = root.appendingPathComponent("different-checkout").path
    environment["GUAVA_TOOL_INVOCATION"] = invocation.path

    try DeveloperTool.run(["native-bootstrap", "--help"], root: root, environment: environment, quiet: true)

    let context = try String(contentsOf: invocation, encoding: .utf8).split(separator: "\n").map(String.init)
    let selected = root.resolvingSymlinksInPath().path
    #expect(context.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == [selected, selected])
}
#endif
