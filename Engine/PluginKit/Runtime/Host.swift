import Swift

@_extern(wasm, module: "cove:process/host", name: "query")
@_extern(c)
private func processQuery(_ request: UnsafeRawPointer?, _ length: Int, _ result: UnsafeMutableRawPointer)

@_extern(wasm, module: "cove:http/host", name: "query")
@_extern(c)
private func httpQuery(_ request: UnsafeRawPointer?, _ length: Int, _ result: UnsafeMutableRawPointer)

/// Host interfaces granted to the plugin by `plugin.json`'s `imports`.
public enum CoveHost {
    /// One `cove:process/host` request: start, poll, write to or stop a
    /// process the manifest permits. Requests and responses are JSON.
    public static func process(_ request: String) -> String {
        call(processQuery, request)
    }

    /// One `cove:http/host` request: start, poll or cancel a host-owned HTTP
    /// transfer to a host the manifest lists. Requests and responses are JSON.
    public static func http(_ request: String) -> String {
        call(httpQuery, request)
    }

    private static func call(_ invoke: (UnsafeRawPointer?, Int, UnsafeMutableRawPointer) -> Void,
                            _ request: String) -> String {
        var request = request
        let area = cabiRealloc(nil, 0, 4, 8).assumingMemoryBound(to: UInt32.self)
        defer { deallocate(UnsafeMutableRawPointer(area)) }
        request.withUTF8 { bytes in invoke(bytes.baseAddress, bytes.count, UnsafeMutableRawPointer(area)) }
        return CanonicalABI.string(UnsafeRawPointer(bitPattern: UInt(area[0])), Int(area[1]))
    }
}
