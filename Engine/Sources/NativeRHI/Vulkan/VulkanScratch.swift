#if canImport(CVulkanHeaders)
/// Owns temporary C argument storage through a native API call. Vulkan copies
/// these descriptors during creation/recording; their pointers never escape.
final class VulkanScratch {
    private var releases: [() -> Void] = []

    func make<Value>(_ value: Value) -> UnsafeMutablePointer<Value> {
        let pointer = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        pointer.initialize(to: value)
        releases.append { pointer.deinitialize(count: 1); pointer.deallocate() }
        return pointer
    }

    func store<Value>(_ values: [Value]) -> UnsafePointer<Value>? {
        guard !values.isEmpty else { return nil }
        let pointer = UnsafeMutablePointer<Value>.allocate(capacity: values.count)
        values.withUnsafeBufferPointer { pointer.initialize(from: $0.baseAddress!, count: values.count) }
        releases.append { pointer.deinitialize(count: values.count); pointer.deallocate() }
        return UnsafePointer(pointer)
    }

    func string(_ value: String) -> UnsafePointer<CChar> {
        store(value.utf8.map { CChar(bitPattern: $0) } + [0])!
    }

    deinit { releases.reversed().forEach { $0() } }
}
#endif
