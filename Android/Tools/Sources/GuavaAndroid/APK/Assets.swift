import Foundation

enum APKAssets {
    static func stage(products: URL, toolchain: AndroidToolchain, launch: SceneLaunch,
                      project: URL?, directory: URL) throws {
        let assets = directory.appendingPathComponent("assets")
        try Files.json(launch, to: assets.appendingPathComponent("launch.json"))
        for name in ["NotoEmoji.ttf", "OFL-Emoji.txt"] {
            try Files.copy(toolchain.root.appendingPathComponent("GuavaUI/Text/Fonts/\(name)"), to: assets.appendingPathComponent("Fonts/\(name)"))
        }
        let libraries = directory.appendingPathComponent("lib/arm64-v8a")
        try Files.copy(products.appendingPathComponent("libGuavaAndroidApp.so"), to: libraries.appendingPathComponent("libGuavaAndroidApp.so"))
        try Files.copy(toolchain.ndkHost().appendingPathComponent("sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"),
                       to: libraries.appendingPathComponent("libc++_shared.so"))
        for bundle in try Files.children(products) where ["bundle", "resources"].contains(bundle.pathExtension) {
            for file in try Files.files(bundle) {
                let relative = Files.relative(file, to: bundle)
                let parts = relative.split(separator: "/").map(String.init)
                if parts.contains("Shaders"), parts.contains("Slang") { continue }
                if let native = parts.firstIndex(of: "Native"), native + 1 < parts.count {
                    let target = parts[native + 1]
                    let expected = bundle.lastPathComponent.contains("RenderBackend") ? "spirv-mobile" : "spirv"
                    if ["metal", "dxil", "spirv", "spirv-mobile"].contains(target), target != expected { continue }
                }
                try Files.copy(file, to: assets.appendingPathComponent(bundle.lastPathComponent).appendingPathComponent(relative))
            }
        }
        if let project {
            for file in try Files.files(project) {
                let relative = Files.relative(file, to: project)
                if relative.hasPrefix(".guava/static-sources/") { continue }
                if file.lastPathComponent == "static-scripts.json" { continue }
                try Files.copy(file, to: assets.appendingPathComponent("GuavaProject").appendingPathComponent(relative))
            }
        }
    }
}
