// swift-tools-version: 6.4
import Foundation
import PackageDescription

/// The standalone Guava SDK checkout. `./guava` and CI provision `GuavaUI/`;
/// `GUAVA_SDK_ROOT` selects another checkout, matching the CLI.
let sdkRoot =
  ProcessInfo.processInfo.environment["GUAVA_SDK_ROOT"]
    .map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "../../GuavaUI"
let decoderHeaders = URL(fileURLWithPath: sdkRoot,
  relativeTo: URL(fileURLWithPath: #filePath).deletingLastPathComponent())
  .appendingPathComponent("Runtime/Sources/Bridge/CImageDecodeBridge").standardizedFileURL.path

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
      name: "RuntimeValidation", dependencies: [.product(name: "ToolSupport", package: "Support")], path: "Sources/Validation/Runtime"),
    .target(
      name: "AndroidValidation", dependencies: [.product(name: "ToolSupport", package: "Support"), "ImageCodec"],
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
  name: "GuavaDeveloper",
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [.executable(name: "guava-dev", targets: ["GuavaDev"])],
  dependencies: [.package(path: "\(sdkRoot)/Tools/Support"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0")],
  targets: infrastructure + buildTools + checks + hostTools + [
    .executableTarget(
      name: "GuavaDev",
      dependencies: [
        .product(name: "ToolSupport", package: "Support"), "Maintainability", "Boundaries", "ShaderToolchain", "VulkanBootstrap",
        "MediaStaging", "PluginStaging", "NativeBootstrap", "RegressionReport", "IOSStaging",
        "IOSSimulator",
      ] + hostDependencies),
    .testTarget(name: "ToolSupportTests", dependencies: [.product(name: "ToolSupport", package: "Support")]),
    .testTarget(name: "ImageCodecTests", dependencies: ["ImageCodec"]),
    .testTarget(name: "MaintainabilityTests", dependencies: ["Maintainability"]),
    .testTarget(name: "BoundaryTests", dependencies: ["Boundaries"]),
    .testTarget(name: "ShaderToolchainTests", dependencies: ["ShaderToolchain"]),
    .testTarget(name: "PluginStagingTests", dependencies: ["PluginStaging"]),
    .testTarget(name: "RegressionReportTests", dependencies: ["RegressionReport"]),
  ] + hostTests
)

// SwiftPM's generated resource accessor uses unqualified imports. Give those
// imports the same narrow default as the first-party source files.
for target in package.targets where target.name != "CImageDecoder" {
  target.swiftSettings = [.enableUpcomingFeature("InternalImportsByDefault")]
}
