/// A recorded rectangular upload from frame-owned or persistent buffer storage.
public struct TextureBufferUpload: Sendable {
    public let buffer: Buffer
    public let texture: Texture
    public var region: TextureUploadRegion
    public var bytesPerRow: Int
    public var offset: Int = 0
    public var subresource = TextureSubresource()

    public init(buffer: Buffer, bytesPerRow: Int, texture: Texture, region: TextureUploadRegion) {
        self.buffer = buffer; self.bytesPerRow = bytesPerRow
        self.texture = texture; self.region = region
    }
}
