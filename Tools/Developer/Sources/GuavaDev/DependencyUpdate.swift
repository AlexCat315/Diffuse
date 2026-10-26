private import Foundation
private import ToolSupport

enum DependencyUpdate {
    static func run(_ arguments: [String]) throws {
        let usage = "./guava studio dependencies <sync|update> natsel"
        if arguments == ["--help"] || arguments == ["-h"] {
            Terminal.info(usage)
            return
        }
        let automatic = arguments == ["sync", "natsel"]
        guard automatic || arguments == ["update", "natsel"] else { throw ToolError.message("Use \(usage)") }
        if automatic {
            if let ci = ProcessInfo.processInfo.environment["CI"], !ci.isEmpty { return }
            guard let remote = try? Shell.output(["git", "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=5",
                                                  "ls-remote", "https://github.com/AlexCat315/Natsel.git", "refs/heads/main"]),
                  let revision = remote.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
            else { return }
            let resolved = ["Engine/Package.resolved", "Editor/Package.resolved", "Package.resolved"].allSatisfy { path in
                guard let data = try? Data(contentsOf: Repository.root.appendingPathComponent(path)),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pins = object["pins"] as? [[String: Any]],
                      let pin = pins.first(where: { $0["identity"] as? String == "natsel" }),
                      let state = pin["state"] as? [String: Any] else { return false }
                return state["branch"] as? String == "main" && state["revision"] as? String == revision
            }
            if resolved { return }
        }
        let swift = ProcessInfo.processInfo.environment["GUAVA_SWIFT_EXECUTABLE"] ?? "swift"
        for package in ["Engine", "Editor", "."] {
            let directory = Repository.root.appendingPathComponent(package).standardizedFileURL
            let repositories = directory.appendingPathComponent(".build/repositories")
            let cached = (try? FileManager.default.contentsOfDirectory(at: repositories, includingPropertiesForKeys: nil)) ?? []
            for repository in cached where repository.lastPathComponent.lowercased().hasPrefix("natsel-") {
                try Shell.inherit(["git", "-C", repository.path, "fetch", "origin"])
            }
            try Shell.inherit([swift, "package", "--package-path", directory.path, "--skip-update", "update", "natsel"])
        }
    }
}
