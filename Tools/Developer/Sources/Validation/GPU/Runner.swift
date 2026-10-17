internal import Foundation
internal import ToolSupport

/// Port of `scripts/test-gpu-regression.sh`, the CI orchestration for the GPU
/// regression job. It runs the fixed inventory in Engine and GuavaUI, tee-ing
/// each command's combined output, then verifies the fresh report directory.
enum Runner {
  /// Fixed suite selections, copied verbatim from the shell script so newly
  /// introduced experiments cannot silently widen the job.
  static let engineFilter = [
    "RenderBackendGPUSmokeTests", "ShaderCatalogTests", "NativeOpaqueTests", "NativePBRTests",
    "NativePostTests", "NativeAnimatedMeshTests", "NativeStylizedTests", "NativeParticleTests",
    "NativeParticleSimulationTests", "NativeParticleInstanceTests", "NativeViewportSurfaceTests",
    "NativeEditorGridTests", "RenderThreadTests",
  ].joined(separator: "|")

  static let uiFilter = [
    "NativeAppWindowTests", "NativeInGameUIIntegrationTests", "NativeInGameUILifecycleTests",
    "NativeViewportIntegrationTests", "NativeDrawListParityTests", "NativeImageAssetTests",
    "NativeUIBindingReuseTests",
  ].joined(separator: "|")

  static func run(_ arguments: [String]) throws {
    if arguments.contains("-h") || arguments.contains("--help") {
      Terminal.info(RegressionReport.usage)
      return
    }
    if let unexpected = arguments.first {
      throw ToolError.message("unrecognized arguments: \(unexpected)")
    }

    let root = Repository.root
    let output =
      override("GUAVA_GPU_TEST_OUTPUT_DIR")
      ?? root.appendingPathComponent("Engine/build/gpu-regression")
    try Fs.directory(output)
    let report = try makeReportDirectory(in: output)

    var environment = ProcessInfo.processInfo.environment
    environment["GUAVA_RUN_GPU_SMOKE_TESTS"] = "1"
    environment["GUAVA_GPU_TEST_OUTPUT_DIR"] = output.path
    let swift = overrideString("GUAVA_SWIFT_EXECUTABLE") ?? "swift"

    try Tee.run(
      [
        swift, "test", "--package-path", root.appendingPathComponent("Engine").path,
        "--filter", engineFilter,
        "--xunit-output", report.appendingPathComponent("gpu-results.xml").path,
      ],
      environment: environment, log: report.appendingPathComponent("gpu.log"))
    try Tee.run(
      [
        swift, "test", "--package-path", root.appendingPathComponent("GuavaUI").path,
        "--filter", uiFilter,
        "--xunit-output", report.appendingPathComponent("ui-results.xml").path,
      ],
      environment: environment, log: report.appendingPathComponent("ui.log"))

    // A successful command that selected no tests, or skipped all GPU
    // tests, must fail this job. Real adapter/pipeline/readback failures
    // also fail Swift tests.
    try Verification.verify(reportDirectory: report)
  }

  /// Reads an environment override, treating an empty value like the shell's
  /// `${VAR:-default}` expansion.
  private static func overrideString(_ name: String) -> String? {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
    return value
  }

  private static func override(_ name: String) -> URL? {
    overrideString(name).map { URL(fileURLWithPath: $0).standardizedFileURL }
  }

  /// `mktemp -d "$output/run-XXXXXX"`: six random alphanumerics, created with
  /// owner-only permissions in the shared output directory.
  private static func makeReportDirectory(in output: URL) throws -> URL {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    for _ in 0..<100 {
      let suffix = String((0..<6).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
      let candidate = output.appendingPathComponent("run-" + suffix)
      if !FileManager.default.fileExists(atPath: candidate.path) {
        try FileManager.default.createDirectory(
          at: candidate, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        return candidate
      }
    }
    throw ToolError.message("Could not create a report directory in \(output.path)")
  }
}
