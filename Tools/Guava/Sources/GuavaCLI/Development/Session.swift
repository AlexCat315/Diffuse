import Foundation
import GuavaUIDevToolsProtocol

struct ManagedSession: Codable {
    struct Device: Codable {
        let adb: String
        let serial: String
        let forwardedPort: Int
    }
    let runtime: DevToolsDiscovery
    let application: ApplicationIdentity
    let platform: AppPlatform
    let configuration: BuildConfiguration
    var device: Device? = nil

    var endpoint: String {
        guard let device, var url = URLComponents(string: runtime.endpoint) else { return runtime.endpoint }
        url.port = device.forwardedPort
        return url.string!
    }
}

final class DevelopmentSession {
    let project: AppProject
    let configuration: BuildConfiguration
    let platform: AppPlatform
    let launch: DevToolsLaunch
    let directory: URL

    init(project: AppProject, configuration: BuildConfiguration, platform: AppPlatform) throws {
        self.project = project; self.configuration = configuration; self.platform = platform
        let id = UUID().uuidString
        directory = project.buildDirectory.appendingPathComponent("devtools/\(id)")
        try Files.directory(directory)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
        launch = DevToolsLaunch(id: id, token: UUID().uuidString + UUID().uuidString,
            descriptorPath: directory.appendingPathComponent("runtime.json").path, appTitle: project.configuration.application.name)
    }

    static func make(project: AppProject, arguments: Arguments) throws -> DevelopmentSession? {
        guard arguments.flags.contains(.devtools) || arguments.configuration == .profile else { return nil }
        return try DevelopmentSession(project: project, configuration: arguments.configuration, platform: arguments.platform)
    }

    func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["GUAVA_DEVTOOLS"] = "1"
        environment["GUAVA_DEVTOOLS_HOST"] = "127.0.0.1"
        environment["GUAVA_DEVTOOLS_PORT"] = "0"
        environment["GUAVA_DEVTOOLS_SESSION_ID"] = launch.id
        environment["GUAVA_DEVTOOLS_TOKEN"] = launch.token
        environment["GUAVA_DEVTOOLS_SESSION_FILE"] = launch.descriptorPath
        return environment
    }

    func publish(_ runtime: DevToolsDiscovery, device: ManagedSession.Device? = nil) throws -> ManagedSession {
        guard runtime.id == launch.id else { throw ToolError.invalid("The application published a different DevTools session") }
        let session = ManagedSession(runtime: runtime, application: project.configuration.application,
                                     platform: platform, configuration: configuration, device: device)
        let file = directory.appendingPathComponent("session.json")
        try Files.json(session, to: file)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #endif
        return session
    }

    func remove() { try? Files.remove(directory) }
}
