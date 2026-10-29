// swift-tools-version: 6.4
import Foundation
import PackageDescription

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

let decoderHeaders = URL(fileURLWithPath: sdkRoot,
  relativeTo: URL(fileURLWithPath: #filePath).deletingLastPathComponent())
  .appendingPathComponent("Imaging/Sources/CImageDecodeBridge").standardizedFileURL.path

let infrastructure: [Target] = [
  .target(name: "CImageDecoder", path: "Sources/Infrastructure/CImageDecoder",
    cSettings: [.unsafeFlags(["-I", decoderHeaders])]),
  .target(
    name: "ImageCodec", dependencies: ["CImageDecoder", .product(name: "ToolSupport", package: "Support")],
    path: "Sources/Infrastructure/ImageCodec"),
]

let buildTools: [Target] = [
  .target(
    name: "ShaderToolchain", dependencies: [.product(name: "ToolSupport", package: "Support")], path: "Sources/Build/ShaderToolchain"),
  .target(
    name: "VulkanBootstrap", dependencies: [.product(name: "ToolSupport", package: "Support")], path: "Sources/Build/VulkanBootstrap"),
  .target(name: "MediaStaging", dependencies: [.product(name: "ToolSupport", package: "Support")], path: "Sources/Build/MediaStaging"),
  .target(
    name: "PluginStaging", dependencies: [.product(name: "ToolSupport", package: "Support")], path: "Sources/Build/PluginStaging"),
  .target(
    name: "NativeBootstrap", dependencies: [.product(name: "ToolSupport", package: "Support"), "MediaStaging", "PluginStaging"],
    path: "Sources/Build/NativeBootstrap"),
  .target(
    name: "IOSStaging", dependencies: [.product(name: "ToolSupport", package: "Support"), "MediaStaging"],
    path: "Sources/Build/IOSStaging"),
]

let checks: [Target] = [
  .target(
    name: "Maintainability", dependencies: [.product(name: "ToolSupport", package: "Support")], path: "Sources/Checks/Maintainability",
    resources: [.copy("swift-maintainability-baseline.json")]),
  .target(name: "Boundaries", dependencies: [.product(name: "ToolSupport", package: "Support")], path: "Sources/Checks/Boundaries"),
  .target(name: "RegressionReport", dependencies: [.product(name: "ToolSupport", package: "Support")], path: "Sources/Validation/GPU"),
  .target(name: "IOSSimulator", dependencies: [.product(name: "ToolSupport", package: "Support")], path: "Sources/Validation/IOS"),
]

// Device/browser harnesses use POSIX descriptors. Windows builds should not
// compile unsupported host APIs just to stage native dependencies.
#if os(Windows)
  let hostTools: [Target] = []
  let hostDependencies: [Target.Dependency] = []
  let hostTests: [Target] = []
#else
  let hostTools: [Target] = [
    .target(
      name: "RuntimeValidation", dependencies: [.product(name: "ToolSupport", package: "Support"), .product(name: "CoveProcess", package: "System")], path: "Sources/Validation/Runtime"),
    .target(
      name: "AndroidValidation", dependencies: [.product(name: "ToolSupport", package: "Support"), .product(name: "CoveProcess", package: "System"), "ImageCodec"],
      path: "Sources/Validation/Android"),
    .target(
      name: "Browser", dependencies: [.product(name: "ToolSupport", package: "Support"), "ImageCodec",
        .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"), .product(name: "NIOWebSocket", package: "swift-nio")],
      path: "Sources/Validation/Browser"),
  ]
  let hostDependencies: [Target.Dependency] = ["RuntimeValidation", "AndroidValidation", "Browser"]
  let hostTests: [Target] = [
    .testTarget(name: "BrowserTests", dependencies: ["Browser", .product(name: "ToolSupport", package: "Support")]),
    .testTarget(name: "RuntimeValidationTests", dependencies: ["RuntimeValidation"]),
  ]
#endif

let package = Package(
  name: "CoveDeveloper",
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [.executable(name: "cove-dev", targets: ["CoveDev"])],
  dependencies: [.package(path: "\(sdkRoot)/Tools/Support"), .package(path: "\(sdkRoot)/System"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0")],
  targets: infrastructure + buildTools + checks + hostTools + [
    .executableTarget(
      name: "CoveDev",
      dependencies: [
        .product(name: "ToolSupport", package: "Support"), "Maintainability", "Boundaries", "ShaderToolchain", "VulkanBootstrap",
        "MediaStaging", "PluginStaging", "NativeBootstrap", "RegressionReport", "IOSStaging",
        "IOSSimulator",
      ] + hostDependencies),
    .testTarget(name: "ToolSupportTests", dependencies: [.product(name: "ToolSupport", package: "Support")]),
    .testTarget(name: "ImageCodecTests", dependencies: ["ImageCodec"]),
    .testTarget(name: "MaintainabilityTests", dependencies: ["Maintainability"]),
    .testTarget(name: "BoundaryTests", dependencies: ["Boundaries"]),
    .testTarget(name: "IOSSimulatorTests", dependencies: ["IOSSimulator"]),
    .testTarget(name: "ShaderToolchainTests", dependencies: ["ShaderToolchain"]),
    .testTarget(name: "MediaStagingTests", dependencies: ["MediaStaging", .product(name: "ToolSupport", package: "Support")]),
    .testTarget(name: "PluginStagingTests", dependencies: ["PluginStaging"]),
    .testTarget(name: "RegressionReportTests", dependencies: ["RegressionReport"]),
  ] + hostTests
)

// SwiftPM's generated resource accessor uses unqualified imports. Give those
// imports the same narrow default as the first-party source files.
for target in package.targets where target.name != "CImageDecoder" {
  target.swiftSettings = [.enableUpcomingFeature("InternalImportsByDefault")]
}
