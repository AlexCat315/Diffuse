import Foundation

struct Arguments {
    let command: String
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ raw: [String]) throws {
        guard let command = raw.first, ["create", "build", "export-game", "compile"].contains(command) else {
            throw ToolError.invalid("Choose create, build or export-game. Use --help for usage.")
        }
        self.command = command
        let common: Set<String> = ["engine-root"]
        let build: Set<String> = ["android-sdk", "ndk", "configuration", "output", "application-id", "name", "serial",
                                  "keystore", "key-alias", "store-password-env", "key-password-env"]
        let allowed: Set<String>
        switch command {
        case "create": allowed = common.union(["directory", "application-id", "name"])
        case "build": allowed = common.union(build).union(["app", "demo", "component"])
        case "export-game": allowed = common.union(build).union(["project"])
        default: allowed = common.union(["ndk", "configuration", "product", "content-package", "gameplay-package", "scratch-path", "result-file"])
        }
        var index = 1
        while index < raw.count {
            let item = raw[index]
            guard item.hasPrefix("--") else { throw ToolError.invalid("Unexpected argument: \(item)") }
            let key = String(item.dropFirst(2))
            if key == "install", command == "build" || command == "export-game" {
                guard !flags.contains(key) else { throw ToolError.invalid("Duplicate --\(key)") }
                flags.insert(key); index += 1; continue
            }
            guard allowed.contains(key), values[key] == nil, index + 1 < raw.count, !raw[index + 1].hasPrefix("--") else {
                throw ToolError.invalid("Unknown, duplicate or missing value for --\(key)")
            }
            values[key] = raw[index + 1]
            index += 2
        }
    }

    func value(_ name: String) -> String? { values[name] }
    func flag(_ name: String) -> Bool { flags.contains(name) }
    func required(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else { throw ToolError.invalid("Supply --\(name)") }
        return value
    }
    func url(_ name: String) -> URL? { values[name].map { URL(fileURLWithPath: $0).standardizedFileURL } }
}
