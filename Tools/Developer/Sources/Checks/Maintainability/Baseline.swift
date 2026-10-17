internal import Foundation
internal import ToolSupport

/// The frozen debt list. Keys are `path::QualifiedType` identities; the values
/// hold the per-metric allowance that must not grow. `reason` strings are
/// documentation and are ignored when loading.
enum Baseline {
  static func allowances() throws -> [String: [String: Int]] {
    guard
      let url = Bundle.module.url(
        forResource: "swift-maintainability-baseline", withExtension: "json")
    else {
      throw ToolError.message("Missing bundled resource swift-maintainability-baseline.json")
    }
    let data = try Fs.read(url)
    do {
      return try JSONDecoder().decode(BaselineFile.self, from: data).declarations.mapValues(
        \.values)
    } catch {
      throw ToolError.message("Cannot decode \(url.lastPathComponent): \(error)")
    }
  }
}

/// Mirrors the baseline file without rejecting its non-numeric `reason` fields.
private struct BaselineFile: Decodable {
  var declarations: [String: Allowances]
}

private struct Allowances: Decodable {
  var values: [String: Int]

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    var values: [String: Int] = [:]
    for key in container.allKeys {
      if let value = try? container.decode(Int.self, forKey: key) {
        values[key.stringValue] = value
      }
    }
    self.values = values
  }
}

private struct AnyCodingKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }

  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}
