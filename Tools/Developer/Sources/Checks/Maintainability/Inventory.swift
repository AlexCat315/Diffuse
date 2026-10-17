internal import Foundation
internal import ToolSupport

/// Walks the first-party Swift packages, measures every declaration, and
/// compares it against the hard limits and the frozen baseline.
enum Inventory {
  /// Package directories whose `Sources` trees are guarded, in scan order.
  static let packageRoots = [
    "Engine", "Engine/Logging", "Engine/Media",
    "Editor", "Editor/Documents",
    "GuavaUI",
    "Tools/Guava",
    "Tools/Developer",
    "Platforms/Android", "Platforms/Android/Contract",
    "GuavaUI/Platforms/Android",
  ]

  struct Declaration {
    var identity: String
    var metrics: DeclarationMetrics
  }

  struct Result {
    var violations: [String]
    var debt: [String]
  }

  /// Measures every guarded declaration in the checkout, keyed by
  /// `path::QualifiedType` in the order the checker first sees it.
  static func declarations() throws -> [Declaration] {
    var ordered = OrderedMap<DeclarationMetrics>()
    for package in packageRoots {
      let sources = Repository.path(package).appendingPathComponent("Sources")
      guard FileManager.default.fileExists(atPath: sources.path) else { continue }
      let files = try Fs.files(in: sources)
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.pathComponents.lexicographicallyPrecedes($1.pathComponents) }
      for file in files {
        let measured = StructuralGuard.measure(try Fs.text(file))
        let relative = Fs.relative(file, to: Repository.root)
        for name in measured.keys {
          guard let metrics = measured[name] else { continue }
          ordered.insert(metrics, for: "\(relative)::\(name)")
        }
      }
    }
    return ordered.keys.compactMap { name in
      ordered[name].map { Declaration(identity: name, metrics: $0) }
    }
  }

  /// Splits measured declarations into hard violations and frozen debt using
  /// the same `allowed = max(limit, baseline allowance)` rule as the Python guard.
  static func evaluate(_ declarations: [Declaration], baseline: [String: [String: Int]]) -> Result {
    var violations: [String] = []
    var debt: [String] = []
    for declaration in declarations {
      for metric in Metric.allCases {
        let actual = declaration.metrics[metric]
        let allowance = baseline[declaration.identity]?[metric.rawValue] ?? metric.limit
        let allowed = max(metric.limit, allowance)
        if actual > allowed {
          violations.append(
            "\(declaration.identity): \(metric.rawValue)=\(actual), allowed=\(allowed)")
        } else if actual > metric.limit {
          debt.append("\(declaration.identity): \(metric.rawValue)=\(actual) (existing debt)")
        }
      }
    }
    return Result(violations: violations, debt: debt)
  }
}
