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

@Test(arguments: [
    ["create", "app"], ["create", "android", "App"], ["create", "app", "App", "--android"],
    ["run", "--android", "--mac"], ["build", "--debug", "--release"], ["run", "--output"],
    ["build", "App", "Other"], ["clean", "--release"], ["test", "--android"],
    ["build", "--mac", "--ndk", "/ndk"], ["run", "--install"],
    ["create", "app", "App", "--id", "a.b", "--id", "c.d"],
    ["doctor", "App"], ["unknown"], ["build", "--configuration", "release"],
    ["build", "--android", "--device", "123"], ["clean", "--engine-root", "/SDK"],
    ["devices", "--ndk", "/NDK"], ["internal", "android-compile", "--mac"],
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
