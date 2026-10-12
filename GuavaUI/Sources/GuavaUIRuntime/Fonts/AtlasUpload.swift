import Foundation
import NativeRHI

extension NativeDrawListRenderer {
    public func uploadFontAtlas(_ atlas: FontAtlas, textureID: TextureID) throws {
        guard textureID > 0 && textureID < 0x8000_0000 else { throw RHIError.invalidArgument("invalid font atlas texture ID") }
        if let payload = atlas.dirtyUploadPayload() {
            var region = TextureUploadRegion(width: payload.region.width, height: payload.region.height)
            region.origin = SIMD2(payload.region.x, payload.region.y)
            try registerTexture(id: textureID, pixels: Data(payload.pixels), size: SIMD2(atlas.atlasWidth, atlas.atlasHeight),
                region: region, format: .r8Unorm)
        }
        if let payload = atlas.colorDirtyUploadPayload() {
            var region = TextureUploadRegion(width: payload.region.width, height: payload.region.height)
            region.origin = SIMD2(payload.region.x, payload.region.y)
            try registerTexture(id: textureID.colorGlyphAtlasID, pixels: Data(payload.pixels),
                size: SIMD2(payload.textureWidth, payload.textureHeight), region: region, format: .rgba8Unorm)
        }
        // CPU payload ownership has transferred to the registry. It stays
        // pending until successful GPU submission acknowledges the frame.
        atlas.markClean()
    }

}
