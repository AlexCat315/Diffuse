public import Foundation

/// One request a plugin asks the host to perform on its behalf. The host owns
/// the socket, the redirect policy and the response bound; a plugin never sees
/// a transport handle.
public struct PluginHTTPMessage: Codable, Sendable, Equatable {
    public enum Method: String, Codable, Sendable, CaseIterable {
        case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
    }

    public var method: Method
    public var url: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: Method, url: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct PluginHTTPResponse: Codable, Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// A transfer outlives the request that started it, so the plugin host's
/// serial request loop never waits on the network. `poll` returns the response
/// once it is ready.
public struct PluginHTTPRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case start, poll, cancel }
    public var operation: Operation
    public var permission: String?
    public var handle: UUID?
    public var message: PluginHTTPMessage?

    public init(_ operation: Operation) { self.operation = operation }
}

public struct PluginHTTPUpdate: Codable, Sendable, Equatable {
    public var handle: UUID
    public var status: Int?
    public var headers: [String: String] = [:]
    public var body: Data = Data()
    public var failure: String?

    public init(handle: UUID) { self.handle = handle }
}

public enum PluginHTTPError: Error, Sendable, Equatable, CustomStringConvertible {
    case notAuthorized
    case invalidRequest
    case domainDenied(String)
    case schemeDenied(String)
    case responseTooLarge
    case transferLimit
    case invalidHandle
    case requestFailed(String)

    public var description: String {
        switch self {
        case .notAuthorized: return "plugin was not granted network access"
        case .invalidRequest: return "invalid HTTP request"
        case let .domainDenied(host): return "HTTP host '\(host)' is not allowed for this plugin"
        case let .schemeDenied(scheme): return "HTTP scheme '\(scheme)' is not allowed"
        case .responseTooLarge: return "HTTP response exceeds the host bound"
        case .transferLimit: return "plugin exceeded its concurrent transfer limit"
        case .invalidHandle: return "HTTP transfer handle is not active"
        case let .requestFailed(reason): return "HTTP request failed: \(reason)"
        }
    }
}

/// Domains and limits a package is allowed to reach. Declared in `plugin.json`
/// under `host.http`, so a package cannot widen its own reach at call time.
public struct PluginHTTPPermission: Codable, Sendable, Equatable {
    public var id: String
    public var hosts: [String]
    public var allowsSubdomains = true
    public var allowsInsecureLocalhost = false
    public var maximumResponseBytes = 8 * 1_024 * 1_024
    public var timeoutMilliseconds = 30_000

    public init(id: String, hosts: [String]) {
        self.id = id
        self.hosts = hosts
    }

    private enum CodingKeys: String, CodingKey {
        case id, hosts, allowsSubdomains, allowsInsecureLocalhost
        case maximumResponseBytes, timeoutMilliseconds
    }

    /// Optional limits fall back to the host default rather than to zero, so a
    /// short manifest stays strictly bounded.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        hosts = try container.decode([String].self, forKey: .hosts)
        allowsSubdomains = try container.decodeIfPresent(Bool.self, forKey: .allowsSubdomains) ?? true
        allowsInsecureLocalhost = try container.decodeIfPresent(Bool.self, forKey: .allowsInsecureLocalhost) ?? false
        maximumResponseBytes = try container.decodeIfPresent(Int.self, forKey: .maximumResponseBytes) ?? 8 * 1_024 * 1_024
        timeoutMilliseconds = try container.decodeIfPresent(Int.self, forKey: .timeoutMilliseconds) ?? 30_000
    }

    /// `*.example.com` matches subdomains only; a bare host matches exactly.
    public func allows(host: String) -> Bool {
        let host = host.lowercased()
        return hosts.contains { rule in
            let rule = rule.lowercased()
            if rule.hasPrefix("*.") {
                let suffix = String(rule.dropFirst(2))
                return allowsSubdomains && host.hasSuffix("." + suffix)
            }
            return host == rule
        }
    }
}
