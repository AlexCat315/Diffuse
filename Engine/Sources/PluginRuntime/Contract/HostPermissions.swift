public import Foundation

public struct PluginHostPermissions: Codable, Sendable, Equatable {
    public var processes: [PluginProcessPermission] = []
    public var http: [PluginHTTPPermission] = []
    public init() {}
    public var entryPoints: Set<String> { Set(processes.flatMap(\.entryPoints)) }

    private enum CodingKeys: String, CodingKey { case processes, http }

    /// Either key may be absent: a package that only reaches the network does
    /// not declare processes, and the reverse. An absent list means none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        processes = try container.decodeIfPresent([PluginProcessPermission].self, forKey: .processes) ?? []
        http = try container.decodeIfPresent([PluginHTTPPermission].self, forKey: .http) ?? []
    }
}

/// A command name is bound to a trusted absolute executable by the host. A
/// package cannot inject a search path, executable path or working directory.
public struct PluginProcessPermission: Codable, Sendable, Equatable {
    public var id: String
    public var command: String
    public var argumentPrefix: [String] = []
    public var allowsAdditionalArguments = false
    public var environmentKeys: [String] = []
    public var entryPoints: [String] = []
    public var lifetimeMilliseconds: Int? = 30_000

    public init(id: String, command: String) { self.id = id; self.command = command }
}

extension PluginHostPermissions {
    func validate(imports: [PluginImportPermission]) throws {
        guard processes.count <= 16, Set(processes.map(\.id)).count == processes.count,
              processes.isEmpty || imports.contains(.process),
              !imports.contains(.process) || !processes.isEmpty else {
            throw PluginManifestValidationError.invalidHostPermissions
        }
        for rule in processes {
            let token = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$"#
            guard rule.id.range(of: token, options: .regularExpression) != nil,
                  rule.command.range(of: token, options: .regularExpression) != nil,
                  rule.argumentPrefix.count <= 32,
                  rule.argumentPrefix.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }),
                  rule.environmentKeys.count <= 32,
                  !rule.entryPoints.isEmpty, rule.entryPoints.count <= 32,
                  rule.entryPoints.allSatisfy({ $0.range(of: #"^[a-z][a-z0-9-]{0,79}$"#, options: .regularExpression) != nil }),
                  rule.environmentKeys.allSatisfy({ $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,79}$"#, options: .regularExpression) != nil }),
                  rule.lifetimeMilliseconds.map({ $0 > 0 && $0 <= 86_400_000 }) ?? true else {
                throw PluginManifestValidationError.invalidHostPermissions
            }
        }
        guard http.count <= 16, Set(http.map(\.id)).count == http.count,
              http.isEmpty || imports.contains(.http),
              !imports.contains(.http) || !http.isEmpty else {
            throw PluginManifestValidationError.invalidHostPermissions
        }
        for rule in http {
            guard rule.id.range(of: #"^[a-z][a-z0-9-]{0,79}$"#, options: .regularExpression) != nil,
                  !rule.hosts.isEmpty, rule.hosts.count <= 64,
                  rule.hosts.allSatisfy({ Self.validHostPattern($0) }),
                  rule.maximumResponseBytes > 0, rule.maximumResponseBytes <= 64 * 1_024 * 1_024,
                  rule.timeoutMilliseconds > 0, rule.timeoutMilliseconds <= 300_000 else {
                throw PluginManifestValidationError.invalidHostPermissions
            }
        }
    }

    /// A host pattern is a bare DNS name or `*.` followed by one, with an
    /// optional port. Rules are matched against the request's parsed host, so
    /// a rule can never smuggle a path or credentials.
    private static func validHostPattern(_ value: String) -> Bool {
        let pattern = #"^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(:\d{1,5})?$"#
        guard !value.contains("/"), !value.contains("@"), !value.contains(" "),
              value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else {
            return false
        }
        let host = value.split(separator: ":").first.map(String.init) ?? value
        return host.count <= 253
    }
}
