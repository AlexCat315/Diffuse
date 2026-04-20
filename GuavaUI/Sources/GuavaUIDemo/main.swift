import GuavaUIRuntime

// -- Text rendering demo --
let atlas = FontAtlas(width: 1024, height: 256)
atlas.loadFont(path: "/System/Library/Fonts/PingFang.ttc", size: 36)

let shaper = TextShaper()
shaper.setFont(ftFace: atlas.freetypeFace!, size: 36)

let text = "Hello, GuavaUI! 🎨\n排版引擎 Phase 4 — HarfBuzz + FreeType"
let shaped = shaper.shape(text: text)

let fbWidth = 1280
let fbHeight = 720
let result = TextLayout.layout(
    shapedGlyphs: shaped,
    text: text,
    atlas: atlas,
    maxWidth: Float(fbWidth - 80),
    lineHeight: 48
)

// Composite glyphs onto a framebuffer
var framebuffer = [UInt8](repeating: 0, count: fbWidth * fbHeight)
let offsetX = 40
let offsetY = 40

for line in result.lines {
    for glyph in line.glyphs {
        guard let info = glyph.atlasInfo, info.width > 0, info.height > 0 else { continue }
        let srcX = Int(info.uvMinX * Float(atlas.atlasWidth))
        let srcY = Int(info.uvMinY * Float(atlas.atlasHeight))
        let dstX = offsetX + Int(glyph.x) + info.bearingX
        let dstY = offsetY + Int(glyph.y) - info.bearingY

        for row in 0..<info.height {
            for col in 0..<info.width {
                let dx = dstX + col
                let dy = dstY + row
                guard dx >= 0, dx < fbWidth, dy >= 0, dy < fbHeight else { continue }
                let srcIdx = (srcY + row) * atlas.atlasWidth + (srcX + col)
                let dstIdx = dy * fbWidth + dx
                framebuffer[dstIdx] = max(framebuffer[dstIdx], atlas.atlasData[srcIdx])
            }
        }
    }
}

// -- Window --
let tree = NodeTree()
let host = SDL3PlatformHost(title: "GuavaUI — Text Demo")

#if canImport(Metal)
if let renderer = TextDemoRenderer() {
    renderer.uploadFramebuffer(framebuffer, width: fbWidth, height: fbHeight)
    host.onFrame = { surface in
        renderer.render(surface: surface)
    }
}
#endif

host.run(tree: tree)
