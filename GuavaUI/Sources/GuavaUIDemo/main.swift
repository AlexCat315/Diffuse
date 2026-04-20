import GuavaUIRuntime

// -- Font provider with CoreText fallback --
let provider = FontProvider(size: 36)
provider.loadPrimaryFont(name: "Helvetica Neue")

let text = "Hello, GuavaUI! 🎨\n排版引擎 Phase 4 — HarfBuzz + FreeType"

// Resolve font runs (CoreText picks the right font per script)
let runs = provider.resolveRuns(text: text)

// Shape each run with auto-detected script/language
var allGlyphs: [ShapedGlyph] = []
for run in runs {
    allGlyphs.append(contentsOf: provider.shapeRun(run))
}

// Shared atlas — register every discovered font
let atlas = FontAtlas(width: 2048, height: 512)
provider.registerAllFonts(in: atlas)

let fbWidth = 1280
let fbHeight = 720
let result = TextLayout.layout(
    shapedGlyphs: allGlyphs,
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
