// swift-tools-version: 6.4
import PackageDescription
import Foundation

let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Editor").standardizedFileURL
let document = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("cove.json"))) as! [String: Any]
let requiredSDK = (document["toolchain"] as! [String: String])["sdkVersion"]!
let environment = ProcessInfo.processInfo.environment
#if os(Windows)
let sdkHome = environment["COVE_HOME"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: environment["LOCALAPPDATA"]!).appendingPathComponent("Cove")
#elseif os(Linux)
let sdkHome = environment["COVE_HOME"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: environment["XDG_DATA_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share").path).appendingPathComponent("cove")
#else
let sdkHome = environment["COVE_HOME"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cove")
#endif
func sdkSelection(_ file: URL) -> URL? {
    guard let data = try? Data(contentsOf: file),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          let path = value["path"] else { return nil }
    return URL(fileURLWithPath: path)
}
func sdkVersion(_ root: URL) -> String? {
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path),
          let data = try? Data(contentsOf: root.appendingPathComponent("Tools/Cove/Sources/CoveCLI/SDK.json")),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
    return value["version"]
}
let overrideSDK = environment["COVE_SDK_ROOT"].map { URL(fileURLWithPath: $0) }
    ?? sdkSelection(directory.appendingPathComponent(".cove/sdk.json"))
let selectedSDK = sdkSelection(sdkHome.appendingPathComponent("sdk.json"))
let installedSDKs = (try? FileManager.default.contentsOfDirectory(at: sdkHome.appendingPathComponent("versions"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
let candidates = ([selectedSDK].compactMap { $0 } + installedSDKs).filter { sdkVersion($0) != nil }
let resolvedSDK = overrideSDK ?? (requiredSDK == "latest"
    ? candidates.max { sdkVersion($0)!.compare(sdkVersion($1)!, options: .numeric) == .orderedAscending }
    : candidates.first { sdkVersion($0) == requiredSDK })
guard let resolvedSDK, let actualSDK = sdkVersion(resolvedSDK),
      environment["COVE_SDK_ROOT"] != nil || requiredSDK == "latest" || requiredSDK == actualSDK else {
    fatalError("Install the shared Cove SDK with cove sdk install \(requiredSDK), then select it with cove sdk use VERSION or PATH")
}

let sdkRoot = resolvedSDK.resolvingSymlinksInPath().path

let gameplayPath = environment["COVE_ANDROID_GAME_PACKAGE"]
let contentPath = environment["COVE_ANDROID_UI_PACKAGE"]
let showcase = gameplayPath == nil && contentPath == nil

let contentPackages: [Package.Dependency] = contentPath.map { [.package(path: $0)] } ?? []
let contentTargets: [Target.Dependency] = contentPath.map {
    [.product(name: "AppContent", package: URL(fileURLWithPath: $0).lastPathComponent)]
} ?? []
let gamePackages: [Package.Dependency] = gameplayPath.map {
    [.package(path: $0), .package(path: "../../Editor")]
} ?? []
let gameTargets: [Target.Dependency] = gameplayPath.map {
    [.product(name: "CoveAndroidGameplay", package: URL(fileURLWithPath: $0).lastPathComponent),
     .product(name: "GameRuntime", package: "Editor")]
} ?? []
let showcasePackages: [Package.Dependency] = showcase ? [
    .package(path: "\(sdkRoot)/Examples"),
] : []
let showcaseTargets: [Target.Dependency] = showcase ? [
    .product(name: "GalleryContent", package: "Examples"),
    .product(name: "CounterExample", package: "Examples"),
] : []
let applicationSettings: [SwiftSetting] = (gameplayPath == nil ? [] : [.define("COVE_ANDROID_GAME")])
    + (contentPath == nil ? [] : [.define("COVE_ANDROID_UI")])
    + (showcase ? [.define("COVE_ANDROID_SHOWCASE")] : [])

let package = Package(
    name: "CoveAndroid",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "CoveAndroidApp", type: .dynamic, targets: ["CoveAndroidApp"]),
    ],
    dependencies: [
        .package(path: "\(sdkRoot)/Hosts/Android/Contract"), .package(path: "../../Engine"),
        .package(name: "CoveUI", path: sdkRoot),
        .package(path: "\(sdkRoot)/DevTools"),
        .package(path: "\(sdkRoot)/Graphics"),
        .package(path: "\(sdkRoot)/Logging"),
        .package(path: "\(sdkRoot)/Runtime"),
    ] + contentPackages + gamePackages + showcasePackages,
    targets: [
        .target(name: "CAndroidHost", dependencies: [.product(name: "CCoveLog", package: "Logging")], publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("android"), .linkedLibrary("log")]),
        .target(name: "CoveAndroidApp", dependencies: [.product(name: "CoveLogging", package: "Logging"),
            .product(name: "CoveAndroidContract", package: "Contract"),
            .product(name: "CoveUIGraphics", package: "Graphics"),
            .product(name: "RenderBackend", package: "Engine"),
            .product(name: "CoveUIRuntime", package: "Runtime"),
            .product(name: "CoveUIAndroid", package: "CoveUI"),
                .product(name: "CoveUIDevTools", package: "DevTools"), "CAndroidHost",
        ] + contentTargets + gameTargets + showcaseTargets,
            swiftSettings: applicationSettings,
            linkerSettings: [.linkedLibrary("ssl"), .linkedLibrary("crypto"), .linkedLibrary("z"),
                .unsafeFlags(["-Xlinker", "-z", "-Xlinker", "defs"])]),
    ]
)
