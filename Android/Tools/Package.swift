// swift-tools-version: 6.4
import PackageDescription

// Host-side tooling deliberately has no engine, UI or Python dependency.
let package = Package(
    name: "GuavaAndroidTools",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GuavaAndroid", targets: ["GuavaAndroid"])],
    targets: [.executableTarget(name: "GuavaAndroid", resources: [.copy("Templates")])]
)
