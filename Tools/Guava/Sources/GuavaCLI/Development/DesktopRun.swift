import Foundation
import GuavaUIDevToolsProtocol

enum DesktopRun {
    static func run(_ executable: URL, project: AppProject, root: URL, arguments: Arguments) throws {
        guard let development = try DevelopmentSession.make(project: project, arguments: arguments) else {
            try Shell.run([executable.path], at: project.directory)
            return
        }
        defer { development.remove() }
        let cancellation = RunCancellation()
        let process = try Shell.start([executable.path], at: project.directory, environment: development.environment())
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(20)
        var runtime: DevToolsDiscovery?
        while process.isRunning, Date() < deadline, !cancellation.isCancelled {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: development.launch.descriptorPath)),
               let found = try? JSONDecoder().decode(DevToolsDiscovery.self, from: data) { runtime = found; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let runtime else {
            if cancellation.isCancelled { return }
            throw ToolError.invalid("Application did not publish its DevTools endpoint; check its startup log and diagnostics configuration")
        }
        let session = try development.publish(runtime)
        try Inspector.present(session, root: root, open: arguments.flags.contains(.devtools) && !arguments.flags.contains(.noOpen))
        while process.isRunning, !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.1) }
        if !process.isRunning { process.waitUntilExit() }
        if !cancellation.isCancelled, process.terminationStatus != 0 { throw ToolError.failed(executable.path, process.terminationStatus) }
    }
}
