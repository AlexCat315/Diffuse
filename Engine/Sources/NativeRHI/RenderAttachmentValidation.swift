func rhiValidateSampleCount(_ count: Int) throws {
    try rhiRequire([1, 2, 4, 8, 16, 32, 64].contains(count), "invalid sample count")
}

func rhiValidateTextureSamples(_ descriptor: TextureDescriptor) throws {
    try rhiValidateSampleCount(descriptor.sampleCount)
    guard descriptor.sampleCount > 1 else { return }
    try rhiRequire(descriptor.dimension == .texture2D && descriptor.depth == 1
        && descriptor.layers == 1 && descriptor.mipLevels == 1,
        "multisampled textures require one 2D layer and one mip")
    try rhiRequire(!descriptor.usage.contains(.storageWrite) && !descriptor.usage.contains(.storageRead)
        && !descriptor.usage.contains(.sampled) && !descriptor.usage.contains(.present),
        "multisampled shader bindings or presentation textures are unsupported; resolve before sampling")
    try rhiRequire(descriptor.usage.contains(.colorTarget) || descriptor.usage.contains(.depthStencilTarget),
                   "multisampled textures require attachment usage")
}

/// Actual backend resource metadata, rather than caller-provided render extents.
struct RenderTextureInfo<Format: Equatable> {
    var supportsColorResolve = true
    let extent: SIMD2<Int>
    let sampleCount: Int
    let format: Format
    let usage: TextureUsage
    let singleLayer2D: Bool
    let isDepth: Bool
}

struct RenderPassSignature<Format: Equatable> {
    let extent: SIMD2<Int>
    let sampleCount: Int
    let colors: [Format]
    let depth: Format?

    func validate(colors: [Format], depth: Format?, samples: Int) throws {
        try rhiRequire(self.colors == colors && self.depth == depth,
                       "pipeline formats do not match render attachments")
        try rhiRequire(sampleCount == samples, "pipeline sample count does not match render attachments")
    }
}

func rhiRenderPassSignature<Format>(_ pass: RenderPassDescriptor,
    describe: (Texture) throws -> RenderTextureInfo<Format>) throws -> RenderPassSignature<Format> {
    let sources = pass.colorTargets.map(\.texture) + (pass.depthTarget.map { [$0.texture] } ?? [])
    let resolves = pass.colorTargets.compactMap(\.resolveTexture)
    try rhiRequire(!sources.isEmpty && pass.colorTargets.count <= 8,
                   "render pass requires attachments and at most eight color targets")
    try rhiRequire(Set((sources + resolves).map(\.id)).count == sources.count + resolves.count,
                   "render attachments and resolve destinations must be distinct")
    let first = try describe(sources[0])
    for texture in sources {
        let info = try describe(texture)
        try rhiRequire(info.extent == first.extent && info.sampleCount == first.sampleCount,
                       "render attachments have different dimensions or sample counts")
        try rhiRequire(info.singleLayer2D, "render attachments require single-layer 2D textures")
    }
    let colors = try pass.colorTargets.map { target in
        let source = try describe(target.texture)
        try rhiRequire(source.usage.contains(.colorTarget) && !source.isDepth,
                       "invalid render color attachment")
        if let texture = target.resolveTexture {
            let resolve = try describe(texture)
            try rhiRequire(source.sampleCount > 1 && resolve.sampleCount == 1
                && resolve.extent == source.extent && resolve.format == source.format
                && resolve.singleLayer2D && resolve.usage.contains(.colorTarget) && !resolve.isDepth,
                "resolve requires matching multisample and single-sample color targets")
            try rhiRequire(source.supportsColorResolve, "color format does not support average multisample resolve")
        }
        return source.format
    }
    let depth = try pass.depthTarget.map { target in
        let info = try describe(target.texture)
        try rhiRequire(info.usage.contains(.depthStencilTarget) && info.isDepth,
                       "invalid render depth attachment")
        return info.format
    }
    return RenderPassSignature(extent: first.extent, sampleCount: first.sampleCount, colors: colors, depth: depth)
}
