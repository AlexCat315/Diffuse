import Foundation

struct ProjectConfiguration: Codable, Equatable {
    struct Toolchain: Codable, Equatable {
        var enginePath: String
    }

    struct Targets: Codable, Equatable {
        var platforms: [AppPlatform] = [.mac, .win, .linux, .android]
        var desktopProduct = "DesktopApp"

        enum CodingKeys: CodingKey { case platforms, desktopProduct }
        init() {}
        init(from decoder: Decoder) throws {
            self.init()
            let values = try decoder.container(keyedBy: CodingKeys.self)
            platforms = try values.decodeIfPresent([AppPlatform].self, forKey: .platforms) ?? platforms
            desktopProduct = try values.decodeIfPresent(String.self, forKey: .desktopProduct) ?? desktopProduct
        }

        func validate() throws {
            guard !platforms.isEmpty, Set(platforms).count == platforms.count else {
                throw ToolError.invalid("targets.platforms must contain unique platform names")
            }
            guard desktopProduct.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else {
                throw ToolError.invalid("targets.desktopProduct must be an executable product name")
            }
        }
    }

    var application: ApplicationIdentity
    var toolchain: Toolchain
    var targets = Targets()

    enum CodingKeys: CodingKey { case application, toolchain, targets }
    init(application: ApplicationIdentity, toolchain: Toolchain) {
        self.application = application
        self.toolchain = toolchain
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        application = try values.decode(ApplicationIdentity.self, forKey: .application)
        toolchain = try values.decode(Toolchain.self, forKey: .toolchain)
        targets = try values.decodeIfPresent(Targets.self, forKey: .targets) ?? targets
    }

    func validate() throws {
        try application.validate()
        try targets.validate()
        guard !toolchain.enginePath.isEmpty else { throw ToolError.invalid("toolchain.enginePath must name the Guava SDK checkout") }
    }
}

struct AppProject {
    let directory: URL
    let configuration: ProjectConfiguration
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
        // Only this generated subtree is owned by the CLI. Other .guava data may be authored.
        let build = buildDirectory
        guard (try? build.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? build.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw ToolError.invalid("Refusing to clean a symlink at \(build.path)")
        }
        try Files.remove(build)
    }
}
