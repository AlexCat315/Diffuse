extension DrawListRenderer {
    /// Publish both dirty planes before clearing either. A failed color
    /// upload leaves the atlas dirty so the next frame can retry it.
    public func uploadFontAtlas(_ atlas: FontAtlas, textureID: TextureID) throws {
        if let payload = atlas.dirtyUploadPayload() {
            try payload.pixels.withUnsafeBufferPointer { bytes in
                try registerAlphaTexture(id: textureID, pixels: bytes.baseAddress!,
                    width: UInt32(payload.region.width), height: UInt32(payload.region.height),
                    originX: UInt32(payload.region.x), originY: UInt32(payload.region.y),
                    textureWidth: UInt32(atlas.atlasWidth), textureHeight: UInt32(atlas.atlasHeight))
            }
        }
        if let payload = atlas.colorDirtyUploadPayload() {
            try payload.pixels.withUnsafeBufferPointer { bytes in
                try registerColorTexture(id: textureID.colorGlyphAtlasID, pixels: bytes.baseAddress!,
                    width: UInt32(payload.region.width), height: UInt32(payload.region.height),
                    originX: UInt32(payload.region.x), originY: UInt32(payload.region.y),
                    textureWidth: UInt32(payload.textureWidth), textureHeight: UInt32(payload.textureHeight))
            }
        }
        atlas.markClean()
    }
}
