import Foundation

/// A managed SDK view binds the installed Swift libraries to the selected NDK.
/// This never edits the installed SDK or the NDK, and different NDKs use separate caches.
struct AndroidSDKOverlay {
    let toolchain: AndroidToolchain
    let host: URL

    func prepare(overrides: Data) throws -> URL {
        let output = try Shell.run([toolchain.swift, "sdk", "configure", "--show-configuration", AndroidToolchain.sdkID,
            AndroidToolchain.triple], capture: true, quiet: true)
        let entries = Dictionary(uniqueKeysWithValues: output.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1].trimmingCharacters(in: .whitespaces)) : nil
        })
        guard let dynamic = entries["swiftResourcesPath"], let `static` = entries["swiftStaticResourcesPath"] else {
            throw ToolError.invalid("The selected Swift Android SDK does not provide its library paths")
        }
        var source = URL(fileURLWithPath: dynamic)
        while !FileManager.default.fileExists(atPath: source.appendingPathComponent("swift-sdk.json").path) {
            let parent = source.deletingLastPathComponent()
            guard parent != source else { throw ToolError.invalid("Cannot locate the installed Swift SDK metadata") }
            source = parent
        }
        let key = (toolchain.ndk.path + source.path).utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let directory = toolchain.cache.appendingPathComponent("swift-sdks/\(String(key, radix: 16))")
        let bundle = directory.appendingPathComponent(source.deletingLastPathComponent().lastPathComponent)
        let sdk = bundle.appendingPathComponent(source.lastPathComponent)
        try Files.directory(sdk)
        try Files.copy(source.deletingLastPathComponent().appendingPathComponent("info.json"), to: bundle.appendingPathComponent("info.json"))
        try Files.copy(source.appendingPathComponent("swift-sdk.json"), to: sdk.appendingPathComponent("swift-sdk.json"))
        for item in try Files.children(source) where !["ndk-sysroot", "swift-sdk.json", "swift-toolset.json"].contains(item.lastPathComponent) {
            try link(item, to: sdk.appendingPathComponent(item.lastPathComponent))
        }
        var original = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("swift-toolset.json"))) as! [String: Any]
        let replacements = try JSONSerialization.jsonObject(with: overrides) as! [String: Any]
        for (name, replacement) in replacements where name != "schemaVersion" {
            guard let replacement = replacement as? [String: Any] else { continue }
            var tool = original[name] as? [String: Any] ?? [:]
            if let path = replacement["path"] { tool["path"] = path }
            tool["extraCLIOptions"] = (tool["extraCLIOptions"] as? [String] ?? []) + (replacement["extraCLIOptions"] as? [String] ?? [])
            original[name] = tool
        }
        var compiler = original["swiftCompiler"] as! [String: Any]
        compiler["extraCLIOptions"] = (compiler["extraCLIOptions"] as? [String] ?? [])
            + ["-L", URL(fileURLWithPath: `static`).appendingPathComponent("android").path,
               "-resource-dir", `static`, "-static-stdlib"]
        original["swiftCompiler"] = compiler
        try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys]).write(to: sdk.appendingPathComponent("swift-toolset.json"), options: .atomic)
        let sysroot = sdk.appendingPathComponent("ndk-sysroot")
        try Files.directory(sysroot.appendingPathComponent("usr/lib"))
        try link(host.appendingPathComponent("sysroot/usr/include"), to: sysroot.appendingPathComponent("usr/include"))
        for item in try Files.children(host.appendingPathComponent("sysroot/usr/lib")) {
            try link(item, to: sysroot.appendingPathComponent("usr/lib/\(item.lastPathComponent)"))
        }
        for (folder, resources) in [("swift", dynamic), ("swift_static", `static`)] {
            let destination = sysroot.appendingPathComponent("usr/lib/\(folder)/android/aarch64/swiftrt.o")
            try Files.directory(destination.deletingLastPathComponent())
            try link(URL(fileURLWithPath: resources).appendingPathComponent("android/aarch64/swiftrt.o"), to: destination)
        }
        return directory
    }

    private func link(_ source: URL, to destination: URL) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == source.path { return }
        try Files.remove(destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
    }
}
