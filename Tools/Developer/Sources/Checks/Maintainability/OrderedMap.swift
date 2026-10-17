/// Insertion-ordered string map. The guard's reports and the baseline walk must
/// keep the order declarations were first seen, exactly like the Python
/// dictionaries they replace, while a later duplicate key overwrites the value
/// in place instead of moving it.
struct OrderedMap<Value> {
  private(set) var keys: [String] = []
  private var storage: [String: Value] = [:]

  subscript(key: String) -> Value? { storage[key] }

  mutating func insert(_ value: Value, for key: String) {
    if storage[key] == nil { keys.append(key) }
    storage[key] = value
  }
}
