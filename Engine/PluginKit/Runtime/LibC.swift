import Swift

// The few C library entry points Embedded Swift's runtime expects. A guest
// has no console, so diagnostics written by a trap go nowhere.

@_cdecl("memcmp")
func memcmp(_ lhs: UnsafeRawPointer, _ rhs: UnsafeRawPointer, _ count: Int) -> Int32 {
    let left = lhs.assumingMemoryBound(to: UInt8.self), right = rhs.assumingMemoryBound(to: UInt8.self)
    var index = 0
    while index < count {
        if left[index] != right[index] { return left[index] < right[index] ? -1 : 1 }
        index += 1
    }
    return 0
}

@_cdecl("putchar")
func putchar(_ character: Int32) -> Int32 { character }
