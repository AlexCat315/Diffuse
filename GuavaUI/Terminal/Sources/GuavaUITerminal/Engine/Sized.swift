/// Sets a Ghostty "sized struct"'s leading `size` field. Ghostty rejects sized
/// structs whose size does not match the caller's layout.
func sized<T>(_ value: T) -> T {
    var value = value
    withUnsafeMutableBytes(of: &value) { $0.storeBytes(of: MemoryLayout<T>.size, as: Int.self) }
    return value
}
