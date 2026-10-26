internal import Foundation
internal import ToolSupport

/// Port of `scripts/verify-gpu-regression.py`: it verifies the current run's
/// Swift Testing xUnit XML and completed XCTest results, so a successful
/// command that selected no tests, or skipped all GPU tests, fails the job.
enum Verification {
  /// The fixed regression inventories. A newly introduced hardware or
  /// performance experiment must not silently make the CI job unbounded.
  static let engineSuites: Set<String> = [
    "RenderBackendGPUSmokeTests", "ShaderCatalogTests", "RenderThreadTests",
    "NativeOpaqueTests", "NativePBRTests", "NativePostTests", "NativeAnimatedMeshTests",
    "NativeStylizedTests", "NativeParticleTests", "NativeParticleSimulationTests",
    "NativeParticleInstanceTests", "NativeViewportSurfaceTests", "NativeEditorGridTests",
  ]
  static let uiSuites: Set<String> = [
    "NativeAppWindowTests", "NativeInGameUIIntegrationTests", "NativeInGameUILifecycleTests",
    "NativeViewportIntegrationTests", "NativeDrawListParityTests", "NativeImageAssetTests",
    "NativeUIBindingReuseTests",
  ]
  static let engineMethods: Set<String> = ["productionScenes", "editorGrid"]
  static let uiMethods: Set<String> = [
    "testWindowTargetsResizeSuspendAndCloseIndependently", "recordingConstantsAreIndependent",
  ]

  /// Completes the fixed inventory, then reports how many test functions ran.
  static func verify(reportDirectory: URL) throws {
    let engine = try loadCases(reportDirectory: reportDirectory, prefix: "gpu")
    let ui = try loadCases(reportDirectory: reportDirectory, prefix: "ui")
    try verifyCases(engine, suites: engineSuites, methods: engineMethods)
    try verifyCases(ui, suites: uiSuites, methods: uiMethods)
    Terminal.info(
      "GPU regression verified: \(engine.count) Engine and \(ui.count) CoveUI test functions executed"
    )
  }

  /// SwiftBuild 6.4 does not emit XCTest XML. Parse only completed test-case
  /// records, never starts or suite summaries; an unrun case cannot satisfy CI.
  static func xctestCases(from log: String) throws -> [TestCase] {
    let pattern = #"^Test Case '(.+)' (passed|failed|skipped) \(([0-9.]+) seconds\)\.\s*$"#
    let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    let range = NSRange(log.startIndex..<log.endIndex, in: log)
    var cases: [TestCase] = []
    for match in regex.matches(in: log, range: range) {
      guard let identityRange = Range(match.range(at: 1), in: log),
        let statusRange = Range(match.range(at: 2), in: log),
        let timeRange = Range(match.range(at: 3), in: log)
      else { continue }
      let identity = String(log[identityRange])
      let status = String(log[statusRange])
      var testCase = TestCase(classname: "", name: "", time: String(log[timeRange]))
      let parts: (String, String)
      if identity.hasPrefix("-[") && identity.hasSuffix("]") {
        parts = try splitLast(String(identity.dropFirst(2).dropLast()), on: " ")
      } else {
        parts = try splitLast(identity, on: ".")
      }
      testCase.classname = parts.0
      testCase.name = parts.1
      switch status {
      case "skipped": testCase.hasSkipped = true
      case "failed": testCase.hasFailure = true
      default: break
      }
      cases.append(testCase)
    }
    return cases
  }

  /// Reads the Swift Testing XML plus the XCTest text log, publishes the log
  /// records as `{prefix}-xctest.xml`, and merges the two sources.
  ///
  /// SwiftPM appends `-swift-testing` to its Swift Testing report. The caller
  /// creates a fresh directory, so previous runs cannot satisfy the inventory.
  static func loadCases(reportDirectory directory: URL, prefix: String) throws -> [TestCase] {
    let reports = try matchingReports(in: directory, prefix: prefix)
    guard !reports.isEmpty else {
      throw ToolError.message("\(prefix) regression did not produce an xUnit report")
    }
    var cases: [TestCase] = []
    for report in reports { cases += try XUnit.testCases(at: report) }

    let log = directory.appendingPathComponent("\(prefix).log")
    guard FileManager.default.fileExists(atPath: log.path) else {
      throw ToolError.message("\(prefix) regression did not produce an XCTest log")
    }
    let completed = try xctestCases(from: Fs.text(log))
    try XUnit.write(completed, to: directory.appendingPathComponent("\(prefix)-xctest.xml"))

    // Some SwiftPM versions already include XCTest in the requested XML;
    // drop those duplicates, but never a record that carries a failure.
    let reported = Set(cases.map { CaseIdentity($0) })
    return cases + completed.filter { !reported.contains(CaseIdentity($0)) || $0.childCount > 0 }
  }

  /// Enforces the exact suite/method inventory and rejects any run that
  /// contains a skipped or failed test, even when every required name ran.
  static func verifyCases(_ cases: [TestCase], suites: Set<String>, methods: Set<String>) throws {
    if cases.contains(where: { $0.failsGate }) {
      throw ToolError.message("GPU regression contains skipped or failed tests")
    }
    let executedSuites = Set(cases.map { afterLastDot($0.classname) })
    let executedMethods = Set(cases.map { beforeFirstParen($0.name) })
    let missing = suites.subtracting(executedSuites).union(methods.subtracting(executedMethods))
    if !missing.isEmpty {
      throw ToolError.message(
        "GPU regression inventory is incomplete: \(pythonList(pythonSorted(Array(missing))))")
    }
  }

  /// `directory.glob(f'{prefix}-results*.xml')`, in a deterministic order.
  private static func matchingReports(in directory: URL, prefix: String) throws -> [URL] {
    let entries =
      (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
      ?? []
    return entries.filter {
      let name = $0.lastPathComponent
      return name.hasPrefix("\(prefix)-results") && name.hasSuffix(".xml")
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private struct CaseIdentity: Hashable {
    let classname: String
    let name: String
    init(_ testCase: TestCase) {
      classname = testCase.classname
      name = testCase.name
    }
  }

  private static func splitLast(_ value: String, on separator: Character) throws -> (String, String)
  {
    guard let index = value.lastIndex(of: separator) else {
      throw ToolError.message("not enough values to unpack (expected 2, got 1): '\(value)'")
    }
    return (String(value[..<index]), String(value[value.index(after: index)...]))
  }

  private static func afterLastDot(_ value: String) -> String {
    guard let index = value.lastIndex(of: ".") else { return value }
    return String(value[value.index(after: index)...])
  }

  private static func beforeFirstParen(_ value: String) -> String {
    String(value.prefix(while: { $0 != "(" }))
  }

  /// Python orders strings by code point; Swift's default ordering does not
  /// always agree, so compare Unicode scalar values directly.
  private static func pythonSorted(_ values: [String]) -> [String] {
    values.sorted { left, right in
      let lhs = Array(left.unicodeScalars)
      let rhs = Array(right.unicodeScalars)
      for (a, b) in zip(lhs, rhs) where a != b { return a.value < b.value }
      return lhs.count < rhs.count
    }
  }

  /// Python's `repr` for a list of strings, as printed in the error message.
  private static func pythonList(_ values: [String]) -> String {
    "["
      + values.map {
        "'"
          + $0.replacingOccurrences(of: "\\", with: "\\\\")
          .replacingOccurrences(of: "'", with: "\\'") + "'"
      }.joined(separator: ", ") + "]"
  }
}
