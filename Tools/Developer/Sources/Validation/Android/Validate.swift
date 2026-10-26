internal import Foundation
internal import ToolSupport

/// Port of `scripts/android/validate.py`: cross-compiles and runs the strict
/// NativeRHI/CoveUI Vulkan probes on an ARM64 device.
enum ValidateOperation {
  private static let expected: Set<String> = [
    "layout", "transfer", "compute", "raster-1x", "raster-4x", "coveui-1x", "coveui-4x",
  ]

  static func run(_ arguments: [String]) throws {
    let parsed = try ParsedArguments.parse(
      arguments,
      options: [
        OptionDefinition("--android-sdk", arity: 1),
        OptionDefinition("--ndk", arity: 1),
        OptionDefinition("--serial", arity: 1),
      ], positionals: 0)
    let sdk = try AndroidTools.sdkRoot(parsed.value("--android-sdk"))
    let ndk = try AndroidTools.ndkRoot(parsed.value("--ndk"))
    let adb = try AndroidTools.adbDevice(sdk, parsed.value("--serial"))

    // The probe is ARM64; reject another ABI instead of pushing an unusable ELF.
    let abi = try Command.output(adb + ["shell", "getprop", "ro.product.cpu.abi"])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard abi == "arm64-v8a" else {
      throw ToolError.message("This validation package currently targets arm64-v8a")
    }

    let products = try AndroidTools.build("CoveAndroidProbe", ndk)
    let directory = try AndroidTools.makeRunDirectory("run-")

    let properties = [
      "ro.product.model", "ro.product.cpu.abi", "ro.build.version.release",
      "ro.build.version.sdk", "ro.board.platform",
    ]
    var deviceInfo: [(String, JSON)] = []
    for name in properties {
      let value = try Command.output(adb + ["shell", "getprop", name])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      deviceInfo.append((name, .string(value)))
    }
    try Fs.write(
      JSON.object(deviceInfo).prettyPrinted() + "\n",
      to: directory.appendingPathComponent("device-info.json"))
    try Fs.write(
      try Command.output(adb + ["shell", "cmd", "gpu", "vkjson"]),
      to: directory.appendingPathComponent("vkjson.json"))

    let artifacts = directory.appendingPathComponent("Artifacts")
    try Fs.directory(artifacts)
    let slangc = AndroidTools.root.appendingPathComponent("Engine/vendor/slang/bin/slangc")
    let fixtures = AndroidTools.coveSDKRoot.appendingPathComponent("Runtime/Tests/NativeRHITests/Fixtures")
    for shader in [
      ("compute", "compute", "computeMain", "compute"),
      ("raster.vertex", "raster", "vertexMain", "vertex"),
      ("raster.fragment", "raster", "fragmentMain", "fragment"),
    ] {
      try compileShader(
        source: fixtures.appendingPathComponent(shader.1 + ".slang"),
        entry: shader.2, stage: shader.3,
        output: artifacts.appendingPathComponent(shader.0 + ".json"), slangc: slangc)
    }

    let remote = "/data/local/tmp/cove-rhi-" + directory.lastPathComponent
    try Command.run(adb + ["shell", "mkdir", "-p", remote])
    let libcxx = try AndroidTools.ndkHost(ndk)
      .appendingPathComponent("sysroot/usr/lib/aarch64-linux-android/libc++_shared.so")
    try Command.run(
      adb + [
        "push",
        products.appendingPathComponent("CoveAndroidProbe").path,
        products.appendingPathComponent("CoveUI_CoveUIRuntime.bundle").path,
        artifacts.path, libcxx.path, remote + "/",
      ])
    let command =
      "cd \(AndroidTools.shellQuote(remote)) && chmod 755 CoveAndroidProbe"
      + " && LD_LIBRARY_PATH=. ./CoveAndroidProbe Artifacts results"
    let status = try Command.attempt(adb + ["shell", command], timeout: 120)
    try Fs.write(status.stdout + status.stderr, to: directory.appendingPathComponent("device.log"))
    FileHandle.standardOutput.write(status.stdout)
    try Command.run(adb + ["pull", remote + "/results", directory.path])

    let report = try JSON.parse(Fs.text(directory.appendingPathComponent("results/report.json")))
    let results = report["results"].elements
    let names = results.compactMap { $0["name"].stringValue }
    if status.status != 0 || Set(names) != expected || names.count != expected.count
      || !results.allSatisfy({ $0["passed"].boolValue == true })
    {
      throw ToolError.message("Android validation failed; inspect \(directory.path)")
    }
    try Command.run(adb + ["shell", "rm", "-r", remote])
    let reportPath = directory.appendingPathComponent("results/report.json")
    Terminal.info("All \(expected.count) Android checks passed: \(reportPath.path)")
  }

  /// The Python harness imported `scripts/compile-rhi-shader.py` in-process.
  /// The repository toolchain owns that compiler now, so this re-enters the
  /// same executable's `shader compile` operation for identical artifacts.
  private static func compileShader(
    source: URL, entry: String, stage: String, output: URL, slangc: URL
  ) throws {
    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    try Command.run([
      executable.path, "shader", "compile",
      "--entry", entry, "--stage", stage, "--target", "spirv",
      "--output", output.path, "--slangc", slangc.path,
      "--spirv-profile", "spirv_1_3", "--no-line-directives",
      source.path,
    ])
  }
}
