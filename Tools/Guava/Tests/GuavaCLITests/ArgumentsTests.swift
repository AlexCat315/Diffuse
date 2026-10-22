import Testing
@testable import GuavaCLI

@Test func sharedCommandsUseHostAndDebugByDefault() throws {
    for operation in ["build", "run", "test", "clean"] {
        let request = try Arguments([operation])
        #expect(request.subject == nil)
        #expect(request.platform == .host)
        #expect(request.configuration == .debug)
    }
}

@Test func projectAndPlatformAreIndependentOfOptionOrder() throws {
    let request = try Arguments(["run", "--release", "My App", "--android", "--device", "123"])
    #expect(request.operation == .run)
    #expect(request.subject == "My App")
    #expect(request.platform == .android)
    #expect(request.configuration == .release)
    #expect(request.value(.device) == "123")
}

@Test func createHasOneCrossPlatformProject() throws {
    let request = try Arguments(["create", "app", "My App", "--id", "com.example.app", "--name", "My App"])
    #expect(request.operation == .create)
    #expect(request.value(.id) == "com.example.app")
}

@Test func pluginBuildTakesADirectoryAndAnOutput() throws {
    let request = try Arguments(["plugin", "build", "Editor/Plugins/Git", "--output", "Git.guavaplugin"])
    #expect(request.operation == .pluginBuild)
    #expect(request.subject == "Editor/Plugins/Git")
    #expect(request.value(.output) == "Git.guavaplugin")
}

@Test(arguments: [
    ["create", "app"], ["create", "android", "App"], ["create", "app", "App", "--android"],
    ["run", "--android", "--mac"], ["build", "--debug", "--release"], ["run", "--output"],
    ["build", "App", "Other"], ["clean", "--release"], ["test", "--android"],
    ["build", "--mac", "--ndk", "/ndk"], ["run", "--install"],
    ["create", "app", "App", "--id", "a.b", "--id", "c.d"],
    ["doctor", "App"], ["unknown"], ["build", "--configuration", "release"],
    ["build", "--android", "--device", "123"], ["clean", "--engine-root", "/SDK"],
    ["devices", "--ndk", "/NDK"], ["internal", "android-compile", "--mac"],
    ["plugin"], ["plugin", "build"], ["plugin", "build", "Git", "--mac"], ["plugin", "build", "Git", "--release"],
]) func invalidCommandsFail(arguments: [String]) {
    #expect(throws: (any Error).self) { try Arguments(arguments) }
}

@Test func nativeTemplatesCanBeSelectedWithoutCreatingAPlatformSpecificApp() throws {
    let request = try Arguments(["create", "app", "MyApp", "--platforms", "mac,android"])
    #expect(request.operation == .create)
    #expect(request.value(.platforms) == "mac,android")
    let attach = try Arguments(["devtools", "MyApp", "--session", "session-id", "--no-open"])
    #expect(attach.operation == .devtools && attach.value(.session) == "session-id")
}

@Test func runForwardsApplicationArgumentsAfterSeparator() throws {
    let request = try Arguments(["run", "Gallery", "--mac", "--devtools", "--no-open", "--", "--component", "list", "--width", "390"])
    #expect(request.subject == "Gallery" && request.flags == [.devtools, .noOpen])
    #expect(request.applicationArguments == ["--component", "list", "--width", "390"])
    #expect(try Arguments(["run"]).applicationArguments.isEmpty)
    #expect(throws: (any Error).self) { try Arguments(["build", "--", "--width", "390"]) }
    #expect(throws: (any Error).self) { try Arguments(["run", "--android", "--", "--width", "390"]) }
}

@Test func devtoolsClientActionsResolveToRepositoryOperations() throws {
    let query = try Arguments(["devtools", "Gallery", "--session", "S", "query", #"{"text":"List"}"#])
    #expect(query.subject == "Gallery" && query.value(.session) == "S")
    #expect(query.client == (try DevToolsClient(action: "query", arguments: [#"{"text":"List"}"#])))
    #expect(query.client?.operation == "query-ui" && query.client?.arguments == ["query_ui_nodes", #"{"text":"List"}"#])
    #expect(try Arguments(["devtools", "list"]).client?.arguments == ["--list"])
    #expect(try Arguments(["devtools", "query", "get_diagnostics", "{}"]).client?.arguments == ["get_diagnostics", "{}"])
    #expect(try Arguments(["devtools", "click", "42"]).client?.arguments == ["--click-node", "42"])
    #expect(try Arguments(["devtools", "input", "@events.json"]).client?.operation == "input-ui")
    let capture = try Arguments(["devtools", "capture", "out.jpg", "--settle-ms", "400"])
    #expect(capture.client?.operation == "capture-ui" && capture.client?.arguments == ["out.jpg", "--settle-ms", "400"])
    #expect(try Arguments(["devtools", "Gallery"]).client == nil)
    #expect(throws: (any Error).self) { try Arguments(["devtools", "click"]) }
    #expect(throws: (any Error).self) { try Arguments(["devtools", "click", ""]) }
    #expect(throws: (any Error).self) { try Arguments(["devtools", "activate", "abc"]) }
    #expect(throws: (any Error).self) { try Arguments(["devtools", "--no-open", "list"]) }
}

@Test func inputActionsCanCaptureTransientStatesInTheSameRun() throws {
    #expect(try Arguments(["devtools", "input", "@drag.json", "--capture", "out.jpg"]).client?.arguments
        == ["--input", "@drag.json", "--capture", "out.jpg"])
    #expect(try Arguments(["devtools", "click", "7", "--capture", "out.jpg"]).client?.arguments
        == ["--click-node", "7", "--capture", "out.jpg"])
    #expect(throws: (any Error).self) { try Arguments(["devtools", "input", "@drag.json", "--settle-ms", "4"]) }
}

@Test func activateRunsAnAccessibilityActionByNodeID() throws {
    #expect(try Arguments(["devtools", "activate", "566"]).client?.arguments == ["566"])
    #expect(try Arguments(["devtools", "activate", "566", "increment"]).client?.operation == "activate-ui")
    #expect(throws: (any Error).self) { try Arguments(["devtools", "activate"]) }
    #expect(try Arguments(["devtools", "reveal", "284"]).client?.arguments == ["284", "reveal"])
    #expect(try Arguments(["devtools", "reveal", "284"]).client?.operation == "activate-ui")
    #expect(throws: (any Error).self) { try Arguments(["devtools", "reveal", "x"]) }
    #expect(throws: (any Error).self) { try Arguments(["devtools", "reveal", "1", "2"]) }
}
