import Foundation
import GuavaUIDevToolsProtocol

/// ADB forwarding and the CLI record have the same lifetime as this run session.
enum AndroidRun {
    static func run(apk: URL, project: AppProject, toolchain: AndroidToolchain, arguments: Arguments) throws {
        let development = try DevelopmentSession.make(project: project, arguments: arguments)
        defer { development?.remove() }
        let device = try AndroidDevice.install(apk, toolchain: toolchain, serial: arguments.value(.device),
            identity: project.configuration.application, launch: development?.launch)
        guard let development else { return }
        let adb = toolchain.sdk.appendingPathComponent("platform-tools/adb").path
        let command = [adb, "-s", device]
        let cancellation = RunCancellation()
        defer { _ = try? Shell.run(command + ["shell", "am", "force-stop", project.configuration.application.id], quiet: true) }
        var runtime: DevToolsDiscovery?
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !cancellation.isCancelled {
            let result = try? Shell.run(command + ["exec-out", "run-as", project.configuration.application.id,
                "cat", "files/devtools/\(development.launch.id).json"], capture: true, quiet: true)
            if let result, let descriptor = try? JSONDecoder().decode(DevToolsDiscovery.self, from: Data(result.utf8)) {
                runtime = descriptor; break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let runtime, let port = URLComponents(string: runtime.endpoint)?.port else {
            if cancellation.isCancelled { return }
            throw ToolError.invalid("Android did not publish its DevTools endpoint; inspect the application's startup log")
        }
        let forwarded = try Shell.run(command + ["forward", "tcp:0", "tcp:\(port)"], capture: true, quiet: true)
        guard let hostPort = Int(forwarded) else { throw ToolError.invalid("ADB did not return a forwarded port") }
        defer { _ = try? Shell.run(command + ["forward", "--remove", "tcp:\(hostPort)"], quiet: true) }
        let session = try development.publish(runtime, device: .init(adb: adb, serial: device, forwardedPort: hostPort))
        try Inspector.present(session, root: toolchain.root,
            open: arguments.flags.contains(.devtools) && !arguments.flags.contains(.noOpen))
        while !cancellation.isCancelled {
            if (try? Inspector.isAlive(session)) != true { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}
