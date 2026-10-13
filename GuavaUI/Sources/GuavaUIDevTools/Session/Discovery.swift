import Foundation
import GuavaUIDevToolsProtocol

extension DevTools {
    func publishDiscovery() throws {
        guard let launch = config.launch, let port = server.boundPort else { return }
        var endpoint = URLComponents()
        endpoint.scheme = "ws"; endpoint.host = "127.0.0.1"; endpoint.port = Int(port); endpoint.path = "/"
        endpoint.queryItems = [URLQueryItem(name: "token", value: launch.token)]
        let descriptor = DevToolsDiscovery(id: launch.id, pid: Int(ProcessInfo.processInfo.processIdentifier), endpoint: endpoint.string!)
        let destination = URL(fileURLWithPath: launch.descriptorPath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(descriptor).write(to: destination, options: .atomic)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        #endif
    }
}
