/// A 2D upload rectangle within one mip/array subresource.
public struct TextureUploadRegion: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var origin: SIMD2<Int> = .zero
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}
