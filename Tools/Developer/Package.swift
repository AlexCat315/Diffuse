// swift-tools-version: 6.4
import PackageDescription

let infrastructure: [Target] = [
  .target(name: "ToolSupport", path: "Sources/Infrastructure/ToolSupport"),
  .target(name: "CImageDecoder", path: "Sources/Infrastructure/CImageDecoder"),
  .target(
    name: "ImageCodec", dependencies: ["CImageDecoder", "ToolSupport"],
    path: "Sources/Infrastructure/ImageCodec"),
]

let buildTools: [Target] = [
  .target(
    name: "ShaderToolchain", dependencies: ["ToolSupport"], path: "Sources/Build/ShaderToolchain"),
  .target(
    name: "VulkanBootstrap", dependencies: ["ToolSupport"], path: "Sources/Build/VulkanBootstrap"),
  .target(name: "MediaStaging", dependencies: ["ToolSupport"], path: "Sources/Build/MediaStaging"),
  .target(
    name: "PluginStaging", dependencies: ["ToolSupport"], path: "Sources/Build/PluginStaging"),
  .target(
    name: "NativeBootstrap", dependencies: ["ToolSupport", "MediaStaging", "PluginStaging"],
    path: "Sources/Build/NativeBootstrap"),
  .target(
    name: "IOSStaging", dependencies: ["ToolSupport", "MediaStaging"],
    path: "Sources/Build/IOSStaging"),
]

let checks: [Target] = [
  .target(
    name: "Maintainability", dependencies: ["ToolSupport"], path: "Sources/Checks/Maintainability",
    resources: [.copy("swift-maintainability-baseline.json")]),
  .target(name: "Boundaries", dependencies: ["ToolSupport"], path: "Sources/Checks/Boundaries"),
  .target(name: "RegressionReport", dependencies: ["ToolSupport"], path: "Sources/Validation/GPU"),
  .target(name: "IOSSimulator", dependencies: ["ToolSupport"], path: "Sources/Validation/IOS"),
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
      name: "RuntimeValidation", dependencies: ["ToolSupport"], path: "Sources/Validation/Runtime"),
    .target(
      name: "AndroidValidation", dependencies: ["ToolSupport", "ImageCodec"],
      path: "Sources/Validation/Android"),
    .target(
      name: "Browser", dependencies: ["ToolSupport", "ImageCodec"],
      path: "Sources/Validation/Browser"),
  ]
  let hostDependencies: [Target.Dependency] = ["RuntimeValidation", "AndroidValidation", "Browser"]
  let hostTests: [Target] = [
    .testTarget(name: "BrowserTests", dependencies: ["Browser", "ToolSupport"]),
    .testTarget(name: "RuntimeValidationTests", dependencies: ["RuntimeValidation"]),
  ]
#endif

let package = Package(
  name: "GuavaDeveloper",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "guava-dev", targets: ["GuavaDev"])],
  targets: infrastructure + buildTools + checks + hostTools + [
    .executableTarget(
      name: "GuavaDev",
      dependencies: [
        "ToolSupport", "Maintainability", "Boundaries", "ShaderToolchain", "VulkanBootstrap",
        "MediaStaging", "PluginStaging", "NativeBootstrap", "RegressionReport", "IOSStaging",
        "IOSSimulator",
      ] + hostDependencies),
    .testTarget(name: "ToolSupportTests", dependencies: ["ToolSupport"]),
    .testTarget(name: "ImageCodecTests", dependencies: ["ImageCodec"]),
    .testTarget(name: "MaintainabilityTests", dependencies: ["Maintainability"]),
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
