import Foundation
import Testing
@testable import GuavaCLI

#if !os(Windows)
@Test func developerTasksPreserveResponseFileArgumentsAndUseSelectedSDKRoot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SDK with spaces \(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("Tools/Developer")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data().write(to: package.appendingPathComponent("Package.swift"))
    let swift = root.appendingPathComponent("swift-tool")
    let products = root.appendingPathComponent("tool products")
    try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
    let executable = products.appendingPathComponent("guava-dev")
    try """
    #!/bin/sh
    for argument in "$@"; do
      if [ "$argument" = "--show-bin-path" ]; then printf '%s\\n' "$GUAVA_TOOL_PRODUCTS"; exit 0; fi
    done
    printf '%s\\n' "$@" > "$GUAVA_TOOL_BUILD"
    """.write(to: swift, atomically: true, encoding: .utf8)
    try """
    #!/bin/sh
    printf '%s\\n' "$GUAVA_ROOT" "$PWD" "$@" > "$GUAVA_TOOL_INVOCATION"
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let invocation = root.appendingPathComponent("invocation.txt")
    var environment = ProcessInfo.processInfo.environment
    environment["GUAVA_SWIFT_EXECUTABLE"] = swift.path
    environment["GUAVA_ROOT"] = root.appendingPathComponent("different-checkout").path
    environment["GUAVA_TOOL_INVOCATION"] = invocation.path
    environment["GUAVA_TOOL_PRODUCTS"] = products.path
    environment["GUAVA_TOOL_BUILD"] = root.appendingPathComponent("build.txt").path
    let session = root.appendingPathComponent("session.json")
    try Data(#"{"runtime":{"endpoint":"ws://127.0.0.1:1234"}}"#.utf8).write(to: session)
    let arguments = ["devtools", "query-ui", "@" + session.path, "query_ui_nodes", #"{"text":"Settings"}"#]

    try DeveloperTool.run(arguments, root: root, environment: environment, quiet: true)

    let context = try String(contentsOf: invocation, encoding: .utf8).split(separator: "\n").map(String.init)
    let selected = root.resolvingSymlinksInPath().path
    #expect(context.prefix(2).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == [selected, selected])
    #expect(Array(context.dropFirst(2)) == arguments)
    let build = try String(contentsOfFile: environment["GUAVA_TOOL_BUILD"]!, encoding: .utf8)
    #expect(build.hasPrefix("build\n"))
    #expect(!build.contains("@" + session.path))
}
#endif
