import Swift

// The guest's heap. Embedded Swift allocates through `posix_memalign` and
// `free`; the canonical ABI moves strings in through `cabi_realloc`. Every
// invocation gets a fresh instance, so a segregated free list over
// power-of-two blocks is enough: no fragmentation outlives a call.
//
// The 8 bytes before a payload hold its block's size class and its offset
// from the block start; a free block's first word links the next one.

private let pageBytes: UInt = 65_536
private let headerBytes: UInt = 16
private let smallestClass = 5
private let classCount = 32

nonisolated(unsafe) private var heapTop: UInt = 0
nonisolated(unsafe) private var heapEnd: UInt = 0
nonisolated(unsafe) private var freeLists: UnsafeMutablePointer<UInt>?

private func memoryPages() -> UInt {
    let memory: Int32 = 0
    return UInt(Int32(Builtin.int_wasm_memory_size_Int32(memory._value)))
}

private func growMemory(_ pages: UInt) -> Bool {
    let memory: Int32 = 0, delta = Int32(truncatingIfNeeded: pages)
    return Int32(Builtin.int_wasm_memory_grow_Int32(memory._value, delta._value)) >= 0
}

/// Takes fresh bytes from the end of the heap, growing memory as needed.
private func bump(_ size: UInt) -> UInt? {
    let start = heapTop
    let (end, overflow) = start.addingReportingOverflow(size)
    guard !overflow else { return nil }
    if end > heapEnd {
        let pages = (end - heapEnd + pageBytes - 1) / pageBytes
        guard growMemory(pages) else { return nil }
        heapEnd += pages * pageBytes
    }
    heapTop = end
    return start
}

private func freeListHeads() -> UnsafeMutablePointer<UInt>? {
    if let freeLists { return freeLists }
    // Data and the stack lie below the initial memory's end.
    heapTop = memoryPages() * pageBytes
    heapEnd = heapTop
    guard let start = bump(UInt(classCount * MemoryLayout<UInt>.stride)) else { return nil }
    let lists = UnsafeMutablePointer<UInt>(bitPattern: start)!
    lists.initialize(repeating: 0, count: classCount)
    freeLists = lists
    return lists
}

private func sizeClass(_ bytes: UInt) -> Int? {
    let index = max(smallestClass, UInt.bitWidth - (bytes - 1).leadingZeroBitCount)
    return index < classCount ? index : nil
}

func allocate(_ size: Int, alignment: Int) -> UnsafeMutableRawPointer? {
    let alignment = UInt(max(alignment, 1))
    let padding = alignment > headerBytes ? alignment : 0
    guard size >= 0, let lists = freeListHeads(),
          let index = sizeClass(UInt(size) + headerBytes + padding) else { return nil }
    let block: UInt
    if lists[index] != 0 {
        block = lists[index]
        lists[index] = UnsafePointer<UInt>(bitPattern: block)!.pointee
    } else {
        guard let fresh = bump(1 << UInt(index)) else { return nil }
        block = fresh
    }
    let payload = (block + headerBytes + alignment - 1) / alignment * alignment
    let header = UnsafeMutablePointer<UInt32>(bitPattern: payload - 8)!
    header[0] = UInt32(index)
    header[1] = UInt32(payload - block)
    return UnsafeMutableRawPointer(bitPattern: payload)
}

func deallocate(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer, let lists = freeLists else { return }
    let payload = UInt(bitPattern: pointer)
    let header = UnsafePointer<UInt32>(bitPattern: payload - 8)!
    let index = Int(header[0]), block = payload - UInt(header[1])
    UnsafeMutablePointer<UInt>(bitPattern: block)!.pointee = lists[index]
    lists[index] = block
}

@_cdecl("posix_memalign")
func posixMemalign(_ result: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ alignment: Int, _ size: Int) -> Int32 {
    guard let pointer = allocate(size, alignment: alignment) else { return 12 }
    result.pointee = pointer
    return 0
}

@_cdecl("free")
func free(_ pointer: UnsafeMutableRawPointer?) {
    deallocate(pointer)
}

/// The canonical ABI's allocator: lowered strings and lists land here.
@_expose(wasm, "cabi_realloc")
@_cdecl("cabi_realloc")
func cabiRealloc(_ old: UnsafeMutableRawPointer?, _ oldSize: Int, _ alignment: Int, _ newSize: Int) -> UnsafeMutableRawPointer {
    guard let pointer = allocate(max(newSize, 1), alignment: alignment) else { Builtin.int_trap() }
    if let old {
        pointer.copyMemory(from: old, byteCount: min(oldSize, newSize))
        deallocate(old)
    }
    return pointer
}
