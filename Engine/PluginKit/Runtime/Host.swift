import Swift

@_extern(wasm, module: "guava:process/host", name: "query")
@_extern(c)
private func processQuery(_ request: UnsafeRawPointer?, _ length: Int, _ result: UnsafeMutableRawPointer)

/// Host interfaces granted to the plugin by `plugin.json`'s `imports`.
public enum GuavaHost {
    /// One `guava:process/host` request: start, poll, write to or stop a
    /// process the manifest permits. Requests and responses are JSON.
    public static func process(_ request: String) -> String {
        var request = request
        let area = cabiRealloc(nil, 0, 4, 8).assumingMemoryBound(to: UInt32.self)
        defer { deallocate(UnsafeMutableRawPointer(area)) }
        request.withUTF8 { bytes in processQuery(bytes.baseAddress, bytes.count, UnsafeMutableRawPointer(area)) }
        return CanonicalABI.string(UnsafeRawPointer(bitPattern: UInt(area[0])), Int(area[1]))
    }
}
