import Foundation

/// Frontend discovery is independent of application compilation and platform hosting.
enum Inspector {
    static func present(_ session: ManagedSession, root: URL, open: Bool) throws {
        let page = root.appendingPathComponent("GuavaUI/DevTools/Client/index.html")
        var url = URLComponents(url: page, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "endpoint", value: session.endpoint)]
        print("DevTools session: \(session.runtime.id) (\(session.application.name), \(session.configuration.rawValue))")
        print("Inspector: \(url.url!.absoluteString)")
        guard open else { return }
        #if os(macOS)
        try Shell.run(["open", url.url!.absoluteString])
        #elseif os(Windows)
        try Shell.run(["rundll32.exe", "url.dll,FileProtocolHandler", url.url!.absoluteString])
        #else
        try Shell.run(["xdg-open", url.url!.absoluteString])
        #endif
    }

    static func attach(_ arguments: Arguments, project: AppProject, root: URL) throws {
        let directory = project.buildDirectory.appendingPathComponent("devtools")
        guard FileManager.default.fileExists(atPath: directory.path) else { throw ToolError.invalid("No development session; start guava run --devtools or --profile") }
        let requested = arguments.value(.session)
        var sessions: [ManagedSession] = []
        for child in try Files.children(directory) {
            guard let data = try? Data(contentsOf: child.appendingPathComponent("session.json")),
                  let session = try? JSONDecoder().decode(ManagedSession.self, from: data),
                  requested == nil || session.runtime.id == requested,
                  arguments.requestedPlatform == nil || session.platform == arguments.requestedPlatform else { continue }
            if (try? isAlive(session)) == true { sessions.append(session) }
        }
        guard sessions.count == 1, let session = sessions.first else {
            throw ToolError.invalid(sessions.isEmpty ? "No live DevTools session for this application" : "Multiple live sessions: \(sessions.map { $0.runtime.id }.joined(separator: ", ")); select --session ID")
        }
        try present(session, root: root, open: !arguments.flags.contains(.noOpen))
    }

    static func isAlive(_ session: ManagedSession) throws -> Bool {
        if let device = session.device {
            let pid = try Shell.run([device.adb, "-s", device.serial, "shell", "pidof", session.application.id], capture: true, quiet: true)
            return pid.split(separator: " ").contains(String(session.runtime.pid)[...])
        }
        #if os(Windows)
        let listing = try Shell.run(["tasklist.exe", "/FI", "PID eq \(session.runtime.pid)", "/NH"], capture: true, quiet: true)
        return listing.split(whereSeparator: \.isWhitespace).contains(String(session.runtime.pid)[...])
        #else
        return processIsAlive(session.runtime.pid)
        #endif
    }
}
