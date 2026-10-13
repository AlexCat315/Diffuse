// swift-tools-version: 6.4
import PackageDescription

// Host-side tooling deliberately has no engine, UI or Python dependency.
let package = Package(
    name: "GuavaAndroidTools",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GuavaAndroid", targets: ["GuavaAndroid"])],
    dependencies: [.package(path: "../Contract")],
    targets: [.executableTarget(name: "GuavaAndroid", dependencies: [.product(name: "GuavaAndroidContract", package: "Contract")], resources: [.copy("Templates")])]
)
