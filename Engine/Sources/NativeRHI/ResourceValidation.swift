func rhiByteRange(offset: Int, size: Int, capacity: Int) throws {
    try rhiRequire(offset >= 0 && size >= 0 && size <= capacity && offset <= capacity - size,
                   "resource byte range is out of bounds")
}

func rhiCount(_ value: Int) throws -> UInt32 {
    try rhiRequire(value >= 0 && value <= Int(UInt32.max), "GPU count cannot be represented as UInt32")
    return UInt32(value)
}

extension TextureFormat {
    var byteCount: Int {
        switch self {
        case .invalid: return 0
        case .r8Unorm: return 1
        case .rgba16Float: return 8
        case .rgba32Float: return 16
        default: return 4
        }
    }
    var isDepth: Bool {
        switch self {
        case .depth24Unorm, .depth24UnormStencil8, .depth32Float: return true
        default: return false
        }
    }
}

func rhiTextureTransferBytes(width: Int, height: Int, rowBytes: Int, format: TextureFormat,
                             textureWidth: Int, textureHeight: Int, capacity: Int) throws -> Int {
    let (minimumRow, rowOverflow) = width.multipliedReportingOverflow(by: format.byteCount)
    let (bytes, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: height)
    try rhiRequire(!rowOverflow && !sizeOverflow && !format.isDepth && format.byteCount > 0
        && width > 0 && height > 0 && width <= textureWidth && height <= textureHeight
        && rowBytes >= minimumRow && rowBytes % format.byteCount == 0 && bytes <= capacity,
        "invalid color texture transfer bounds or row pitch")
    return bytes
}
