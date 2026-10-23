#if os(macOS) || os(Linux) || os(Windows)
public import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Performs HTTP for plugins without blocking the plugin host's serial request
/// loop: `start` returns a handle immediately and `poll` reports completion.
/// The package declares reachable hosts in `plugin.json`; anything outside them
/// is refused before a socket opens.
public final class PluginHTTPService: @unchecked Sendable {
    private final class Transfer: @unchecked Sendable {
        let handle = UUID()
        let lock = NSLock()
        let maximumBytes: Int
        var response: PluginHTTPResponse?
        var failure: String?
        var task: URLSessionDataTask?

        init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

        func finish(response: PluginHTTPResponse) {
            lock.withLock { if self.response == nil && failure == nil { self.response = response } }
        }

        func fail(_ message: String) {
            lock.withLock { if self.response == nil && failure == nil { failure = message } }
        }

        func poll() -> (update: PluginHTTPUpdate, finished: Bool) {
            lock.withLock {
                var update = PluginHTTPUpdate(handle: handle)
                if let response {
                    update.status = response.status
                    update.headers = response.headers
                    update.body = Data(response.body.prefix(maximumBytes))
                    update.failure = response.body.count > maximumBytes ? PluginHTTPError.responseTooLarge.description : nil
                    return (update, true)
                }
                if let failure {
                    update.failure = failure
                    return (update, true)
                }
                return (update, false)
            }
        }

        var isFinished: Bool { lock.withLock { response != nil || failure != nil } }
    }

    private struct Mount {
        let generation: UUID
        let permissions: [PluginHTTPPermission]
    }

    private let lock = NSLock()
    private var mounts: [String: Mount] = [:]
    private var transfers: [UUID: Transfer] = [:]
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func mount(inspection: PluginInspection, authorization: PluginAuthorizationRecord) throws {
        guard authorization.isStillValid(for: inspection) else { throw PluginAuthorizationError.noLongerValid }
        let permissions = inspection.manifest.host.http
        lock.withLock {
            mounts[inspection.manifest.id] = Mount(generation: UUID(), permissions: permissions)
        }
    }

    /// Cancels every in-flight transfer the plugin owns; unload must not leave
    /// a socket open past the package's lifetime.
    public func unmount(pluginID: String) {
        let removed: [Transfer] = lock.withLock {
            guard mounts.removeValue(forKey: pluginID) != nil else { return [] }
            let abandoned = transfers.values.filter { $0.task != nil && !$0.isFinished }
            for transfer in abandoned { transfers.removeValue(forKey: transfer.handle) }
            return abandoned
        }
        for transfer in removed {
            transfer.task?.cancel()
            transfer.fail(PluginHTTPError.notAuthorized.description)
        }
    }

    public func response(pluginID: String, request: Data) throws -> Data {
        let decoded = try JSONDecoder().decode(PluginHTTPRequest.self, from: request)
        return try JSONEncoder().encode(perform(pluginID: pluginID, request: decoded))
    }

    public func perform(pluginID: String, request: PluginHTTPRequest) throws -> PluginHTTPUpdate {
        switch request.operation {
        case .start:
            guard let message = request.message else { throw PluginHTTPError.invalidRequest }
            guard let permission = try permission(pluginID: pluginID, message: message) else {
                throw PluginHTTPError.notAuthorized
            }
            let transfer = Transfer(maximumBytes: permission.maximumResponseBytes)
            lock.withLock {
                guard transfers.values.filter({ !$0.isFinished }).count < 8, transfers.count < 32 else {
                    return
                }
                transfers[transfer.handle] = transfer
            }
            guard lock.withLock({ transfers[transfer.handle] != nil }) else { throw PluginHTTPError.transferLimit }
            try start(transfer, message: message, permission: permission)
            return PluginHTTPUpdate(handle: transfer.handle)
        case .poll:
            guard let handle = request.handle,
                  let transfer = lock.withLock({ transfers[handle] }) else {
                throw PluginHTTPError.invalidHandle
            }
            let (update, finished) = transfer.poll()
            if finished { _ = lock.withLock { transfers.removeValue(forKey: handle) } }
            return update
        case .cancel:
            guard let handle = request.handle,
                  let transfer = lock.withLock({ transfers.removeValue(forKey: handle) }) else {
                throw PluginHTTPError.invalidHandle
            }
            transfer.task?.cancel()
            transfer.fail(PluginHTTPError.requestFailed("cancelled").description)
            return PluginHTTPUpdate(handle: handle)
        }
    }

    private func permission(pluginID: String, message: PluginHTTPMessage) throws -> PluginHTTPPermission? {
        guard let mount = lock.withLock({ mounts[pluginID] }) else { throw PluginHTTPError.notAuthorized }
        guard let url = URL(string: message.url),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            throw PluginHTTPError.invalidRequest
        }
        guard let permission = mount.permissions.first(where: { $0.allows(host: host) }) else {
            throw PluginHTTPError.domainDenied(host)
        }
        guard scheme == "https"
                || (scheme == "http" && permission.allowsInsecureLocalhost && Self.isLoopback(host)) else {
            throw PluginHTTPError.schemeDenied(scheme)
        }
        if let body = message.body, body.count > permission.maximumResponseBytes {
            throw PluginHTTPError.responseTooLarge
        }
        return permission
    }

    private func start(_ transfer: Transfer, message: PluginHTTPMessage,
                       permission: PluginHTTPPermission) throws {
        guard let url = URL(string: message.url) else { throw PluginHTTPError.invalidRequest }
        var outgoing = URLRequest(url: url)
        outgoing.httpMethod = message.method.rawValue
        outgoing.httpBody = message.body
        outgoing.timeoutInterval = Double(permission.timeoutMilliseconds) / 1000
        for (name, value) in message.headers {
            outgoing.setValue(value, forHTTPHeaderField: name)
        }
        let maximumBytes = permission.maximumResponseBytes
        let task = session.dataTask(with: outgoing) { data, response, error in
            if let error {
                transfer.fail(error.localizedDescription)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                transfer.fail(PluginHTTPError.invalidRequest.description)
                return
            }
            let body = data ?? Data()
            guard body.count <= maximumBytes else {
                transfer.fail(PluginHTTPError.responseTooLarge.description)
                return
            }
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                guard let name = name as? String, let value = value as? String else { continue }
                headers[name] = value
            }
            transfer.finish(response: PluginHTTPResponse(status: http.statusCode,
                                                         headers: headers, body: body))
        }
        transfer.task = task
        task.resume()
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}
#endif
