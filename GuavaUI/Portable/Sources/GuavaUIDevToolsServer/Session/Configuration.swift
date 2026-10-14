import Foundation
import GuavaUIDevToolsProtocol

/// Configuration for the in-process DevTools WebSocket server.
public struct DevToolsConfig: Sendable {
    public var host: String
    public var port: UInt16
    public var appTitle: String
    public var enabled: Bool
    public var launch: DevToolsLaunch? = nil

    public init(host: String = "127.0.0.1",
                port: UInt16 = 9229,
                appTitle: String = "GuavaUI",
                enabled: Bool = true) {
        self.host = host
        self.port = port
        self.appTitle = appTitle
        self.enabled = enabled
    }

    /// Convenience: enables the server when the `GUAVA_DEVTOOLS=1` env var is set.
    public static func fromEnvironment(appTitle: String = "GuavaUI") -> DevToolsConfig? {
        #if !DEBUG && !GUAVA_PROFILE
        return nil
        #else
        let env = ProcessInfo.processInfo.environment
        guard env["GUAVA_DEVTOOLS"] == "1" else { return nil }
        let host = env["GUAVA_DEVTOOLS_HOST"] ?? "127.0.0.1"
        let port = env["GUAVA_DEVTOOLS_PORT"].flatMap(UInt16.init) ?? 9229
        var config = DevToolsConfig(host: host,
                              port: port,
                              appTitle: appTitle,
                              enabled: true)
        if let id = env["GUAVA_DEVTOOLS_SESSION_ID"], let token = env["GUAVA_DEVTOOLS_TOKEN"],
           let path = env["GUAVA_DEVTOOLS_SESSION_FILE"] {
            config.launch = DevToolsLaunch(id: id, token: token, descriptorPath: path, appTitle: appTitle)
        }
        return config
        #endif
    }
}

public enum DevServerConfigurationError: LocalizedError {
    case unsupportedHost(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedHost(let host):
            return "Unsupported DevTools host '\(host)'. Use localhost/127.0.0.1/::1 for loopback or 0.0.0.0/:: for all interfaces."
        }
    }
}

/// Closure that produces a tree snapshot. The host runtime is responsible
/// for invoking the closure on the main actor / scene thread before the
/// JSON encode happens.
public typealias SceneSnapshotProvider = @MainActor () -> TreeSnapshotPayload

/// Closure invoked when the client requests `select.node`. The host
/// runtime decides what "selecting" means (e.g. drawing an overlay).
public typealias NodeSelectionHandler = @MainActor (_ id: String) -> Void
public typealias NodeSelectionClearHandler = @MainActor () -> Void

/// Schedules DevTools callbacks onto the host's UI thread. Application uses its
/// own main-thread inbox because its SDL loop is synchronous and may not yield
/// to Swift Concurrency `MainActor` tasks while running.
public typealias HostMainExecutor = (@escaping @MainActor () -> Void) -> Void

