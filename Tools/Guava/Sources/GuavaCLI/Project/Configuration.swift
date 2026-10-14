import Foundation

struct ProjectConfiguration: Codable, Equatable {
    struct Toolchain: Codable, Equatable {
        var enginePath: String
    }

    struct Targets: Codable, Equatable {
        var platforms: [AppPlatform] = [.mac, .win, .linux, .android, .ios]
        var desktopExecutable: String? = nil

        enum CodingKeys: CodingKey { case platforms, desktopExecutable }
        init() {}
        init(from decoder: Decoder) throws {
            self.init()
            let values = try decoder.container(keyedBy: CodingKeys.self)
            platforms = try values.decodeIfPresent([AppPlatform].self, forKey: .platforms) ?? platforms
            desktopExecutable = try values.decodeIfPresent(String.self, forKey: .desktopExecutable)
        }

        func validate() throws {
            guard !platforms.isEmpty, Set(platforms).count == platforms.count else {
                throw ToolError.invalid("targets.platforms must contain unique platform names")
            }
            guard desktopExecutable == nil || desktopExecutable!.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else {
                throw ToolError.invalid("targets.desktopExecutable must be an executable product name")
            }
        }
    }

    var application: ApplicationIdentity
    var toolchain: Toolchain
    var targets = Targets()
    var version = ApplicationVersion()

    enum CodingKeys: CodingKey { case application, toolchain, targets, version }
    init(application: ApplicationIdentity, toolchain: Toolchain) {
        self.application = application
        self.toolchain = toolchain
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        application = try values.decode(ApplicationIdentity.self, forKey: .application)
        toolchain = try values.decode(Toolchain.self, forKey: .toolchain)
        targets = try values.decodeIfPresent(Targets.self, forKey: .targets) ?? targets
        version = try values.decode(ApplicationVersion.self, forKey: .version)
    }

    func validate() throws {
        try application.validate()
        try targets.validate()
        try version.validate()
        guard !toolchain.enginePath.isEmpty else { throw ToolError.invalid("toolchain.enginePath must name the Guava SDK checkout") }
    }
}

struct AppProject {
    let directory: URL
    let configuration: ProjectConfiguration
    var desktopProduct: String { configuration.targets.desktopExecutable ?? "Application" }
    var buildDirectory: URL { directory.appendingPathComponent(".guava/build") }

    init(at directory: URL) throws {
        self.directory = directory.standardizedFileURL
        let manifest = directory.appendingPathComponent("guava.json")
        guard FileManager.default.fileExists(atPath: manifest.path),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) else {
            throw ToolError.invalid("\(directory.path) must contain guava.json and Package.swift; use guava create app <directory>")
        }
        configuration = try JSONDecoder().decode(ProjectConfiguration.self, from: Data(contentsOf: manifest))
        try configuration.validate()
    }

    func require(_ platform: AppPlatform) throws {
        try platform.requireAvailable()
        guard configuration.targets.platforms.contains(platform) else {
            throw ToolError.invalid("This application's targets.platforms does not include \(platform.rawValue)")
        }
    }

    func clean() throws {
        let sessions = buildDirectory.appendingPathComponent("devtools")
        if FileManager.default.fileExists(atPath: sessions.path) {
            for directory in try Files.children(sessions) {
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")),
                      let session = try? JSONDecoder().decode(ManagedSession.self, from: data) else { continue }
                if (try? Inspector.isAlive(session)) == true {
                    throw ToolError.invalid("Stop development session \(session.runtime.id) before cleaning this application's build cache")
                }
            }
        }
        // Only this generated subtree is owned by the CLI. Other .guava data may be authored.
        let build = buildDirectory
        guard (try? build.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? build.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw ToolError.invalid("Refusing to clean a symlink at \(build.path)")
        }
        try Files.remove(build)
    }
}
