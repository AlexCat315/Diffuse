/// Retains atlas planes consumed from the snapshot channel until a renderer
/// accepts ownership. Upload/record/submit retries then belong to that renderer.
struct InGameUIAtlasDelivery {
    private var pending: [GlyphAtlasFormat: DrawListAtlasDirty] = [:]

    mutating func collect(_ snapshot: DrawListSnapshot) {
        for update in snapshot.atlasUpdates { pending[update.format] = update }
    }
    mutating func stage(_ upload: (DrawListAtlasDirty) throws -> Void) throws {
        for format in [GlyphAtlasFormat.alpha, .color] {
            guard let update = pending[format] else { continue }
            try upload(update)
            pending.removeValue(forKey: format)
        }
    }
}
