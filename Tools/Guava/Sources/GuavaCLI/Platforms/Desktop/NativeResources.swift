import Foundation

struct NativeDesktopResources {
    let project: AppProject
    let platform: AppPlatform
    var directory: URL { project.directory.appendingPathComponent("Platforms/\(platform.directoryName)") }

    func package(into artifact: DesktopPackage.Artifact, configuration: BuildConfiguration) throws {
        let resources = directory.appendingPathComponent("Resources")
        let target = platform == .mac ? artifact.directory.appendingPathComponent("Contents/Resources") : artifact.directory.appendingPathComponent("Resources")
        if FileManager.default.fileExists(atPath: resources.path) {
            for source in try Files.children(resources) where source.lastPathComponent != "README.md" {
                try Files.copy(source, to: target.appendingPathComponent(source.lastPathComponent))
            }
        }
        switch platform {
        case .mac: try macOS(artifact, configuration: configuration)
        case .win:
            let manifest = directory.appendingPathComponent("Application.manifest")
            try Shell.run(["mt.exe", "-nologo", "-manifest", manifest.path, "-outputresource:\(artifact.executable.path);#1"])
        case .linux: try linux(artifact)
        default: break
        }
    }

    func macOS(_ artifact: DesktopPackage.Artifact, configuration: BuildConfiguration) throws {
        var info = try plist("Info.plist")
        let identity = project.configuration.application, version = project.configuration.version
        let managed: [String: Any] = ["CFBundleIdentifier": identity.id, "CFBundleName": identity.name,
            "CFBundleDisplayName": identity.name, "CFBundleExecutable": project.desktopProduct,
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version.name, "CFBundleVersion": String(version.build)]
        for (key, value) in managed {
            guard info[key] == nil else { throw ToolError.invalid("\(key) is supplied by guava.json / the build; remove the duplicate from Platforms/macOS/Info.plist") }
            info[key] = value
        }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Resources/AppIcon.icns").path) { info["CFBundleIconFile"] = "AppIcon.icns" }
        try write(info, to: artifact.directory.appendingPathComponent("Contents/Info.plist"))
        var entitlements = try plist("Entitlements.plist")
        entitlements["com.apple.security.get-task-allow"] = configuration != .release
        let file = project.buildDirectory.appendingPathComponent("mac/\(configuration.rawValue)/Entitlements.plist")
        try write(entitlements, to: file)
    }

    /// An ad-hoc signature's designated requirement is its code hash, so every
    /// rebuild reads as a new app and Keychain forgets "Always Allow". Development
    /// builds name the bundle identifier instead; release builds keep the hash.
    static func designatedRequirement(identifier: String, configuration: BuildConfiguration) -> [String] {
        configuration == .release ? [] : ["--requirements", "=designated => identifier \"\(identifier)\""]
    }

    func sign(_ artifact: DesktopPackage.Artifact, configuration: BuildConfiguration) throws {
        #if os(macOS)
        if platform == .mac {
            let file = project.buildDirectory.appendingPathComponent("mac/\(configuration.rawValue)/Entitlements.plist")
            for helper in project.configuration.targets.desktopHelpers {
                let executable = artifact.directory.appendingPathComponent("Contents/Helpers/\(helper)")
                try Shell.run(["codesign", "--force", "--sign", "-", executable.path])
            }
            try Shell.run(["codesign", "--force", "--sign", "-", "--entitlements", file.path]
                + Self.designatedRequirement(identifier: project.configuration.application.id, configuration: configuration)
                + [artifact.directory.path])
        }
        #endif
    }

    private func linux(_ artifact: DesktopPackage.Artifact) throws {
        let lines = try String(contentsOf: directory.appendingPathComponent("Application.desktop"), encoding: .utf8).split(separator: "\n").map(String.init)
        guard lines.first == "[Desktop Entry]", !lines.contains(where: { $0.hasPrefix("Name=") || $0.hasPrefix("Exec=") }) else {
            throw ToolError.invalid("Application.desktop requires [Desktop Entry]; Name and Exec are supplied by guava.json / the build")
        }
        let executable = artifact.executable.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let content = (lines + ["Name=\(project.configuration.application.name)", "Exec=\"\(executable)\""]).joined(separator: "\n") + "\n"
        try Files.text(content, to: artifact.directory.appendingPathComponent(project.desktopProduct + ".desktop"))
    }

    private func plist(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ToolError.invalid("\(name) must contain a property-list dictionary")
        }
        return values
    }
    private func write(_ value: [String: Any], to file: URL) throws {
        try Files.directory(file.deletingLastPathComponent())
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: file)
    }
}
