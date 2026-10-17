internal import Foundation

extension JSON {
  /// Mirrors `json.dumps`'s default separators (`", "` and `": "`), used where
  /// the reference scripts print or publish JSON text verbatim, such as the
  /// hardware adapter line and the plugin catalog.
  var compactText: String {
    switch self {
    case .array(let items):
      return "[" + items.map(\.compactText).joined(separator: ", ") + "]"
    case .object(let object):
      return "{"
        + object.map { JSON.quote($0.key) + ": " + $0.value.compactText }.joined(separator: ", ")
        + "}"
    default:
      return serialized
    }
  }
}
