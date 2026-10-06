import Foundation
import XCTest
import GuavaUICore
@testable import GuavaUIText

final class FontPipelineTests: XCTestCase {
    private func bytes(_ name: String) throws -> [UInt8] {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fonts")
        return Array(try Data(contentsOf: directory.appendingPathComponent(name)))
    }
    private func collection() throws -> FontCollection {
        let fonts = FontCollection()
        for name in ["NotoSans.ttf", "NotoSansCJKsc.otf", "NotoSansArabic.ttf", "NotoSansDevanagari.ttf", "NotoEmoji.ttf"] {
            XCTAssertNotNil(fonts.append(bytes: try bytes(name)))
        }
        return fonts
    }

    func testOwnedMemoryAndInvalidFontPreserveCurrentFace() throws {
        let atlas = FontAtlas()
        XCTAssertTrue(atlas.loadFont(bytes: try bytes("NotoSans.ttf"), size: 16))
        let face = atlas.freetypeFace
        XCTAssertFalse(atlas.loadFont(bytes: [1, 2, 3], size: 16))
        XCTAssertEqual(atlas.freetypeFace, face)
        let shaper = TextShaper()
        shaper.setFont(ftFace: atlas.freetypeFace!, size: 16)
        XCTAssertTrue(shaper.shape(text: "memory survives the temporary input array").allSatisfy { $0.glyphID != 0 })
        XCTAssertTrue(atlas.loadFont(bytes: try bytes("NotoSansArabic.ttf"), size: 16))
        XCTAssertTrue(shaper.shape(text: "old face remains alive while HarfBuzz references it").allSatisfy { $0.glyphID != 0 })
    }

    func testGraphemeFallbackPreservesUTF8ClustersAndLigatures() throws {
        let fonts = try collection()
        let text = "office 你好 कि 🙂"
        let shaped = fonts.shape(text)
        XCTAssertFalse(shaped.isEmpty)
        XCTAssertTrue(shaped.allSatisfy { $0.glyphID != 0 })
        // NotoSans also covers Devanagari; the first complete face wins.
        XCTAssertEqual(Set(shaped.map(\.fontID)), [1, 2, 5])
        XCTAssertLessThan(fonts.shape("office").count, "office".count)
        let chineseStart = UInt32("office ".utf8.count)
        XCTAssertTrue(shaped.contains { $0.cluster == chineseStart && $0.fontID == 2 })
        let devanagariStart = UInt32("office 你好 ".utf8.count)
        let devanagari = shaped.filter { $0.cluster == devanagariStart }
        XCTAssertEqual(devanagari.count, 2)
        XCTAssertTrue(devanagari.allSatisfy { $0.fontID == 1 })
    }

    func testArabicAutoDirectionAndJoining() throws {
        let fonts = try collection()
        let shaped = fonts.shape("سلام")
        XCTAssertTrue(shaped.allSatisfy { $0.fontID == 3 && $0.glyphID != 0 })
        XCTAssertGreaterThan(shaped.first!.cluster, shaped.last!.cluster)
        let isolated = "سلام".flatMap { fonts.shape(String($0)).map(\.glyphID) }
        XCTAssertNotEqual(shaped.map(\.glyphID), isolated.reversed())
        XCTAssertGreaterThan(shaped.reduce(0) { $0 + $1.xAdvance }, 0)
    }

    func testDevanagariFallbackKeepsOneGraphemeInOneFace() throws {
        let fonts = FontCollection()
        XCTAssertEqual(fonts.append(bytes: try bytes("NotoSansCJKsc.otf")), 1)
        XCTAssertEqual(fonts.append(bytes: try bytes("NotoSansDevanagari.ttf")), 2)
        let shaped = fonts.shape("कि")
        XCTAssertEqual(shaped.count, 2)
        XCTAssertTrue(shaped.allSatisfy { $0.fontID == 2 && $0.glyphID != 0 && $0.cluster == 0 })
    }

    func testAtlasExhaustionIsReportedAndResetClearsIt() throws {
        let fonts = FontCollection(width: 16, height: 16)
        XCTAssertNotNil(fonts.append(bytes: try bytes("NotoSans.ttf")))
        fonts.draw("W", size: 42, into: DrawList(), x: 0, y: 0, color: .white)
        XCTAssertTrue(fonts.atlas.isFull)
        fonts.atlas.reset()
        XCTAssertFalse(fonts.atlas.isFull)
        XCTAssertEqual(fonts.atlas.dirtyUploadPayload()?.pixels.count, 256)
    }

    func testRasterSizesAndHiDPIReuseCorrectAtlasKeys() throws {
        let fonts = try collection()
        let list = DrawList()
        let small = fonts.draw("Hi 你好", size: 16, into: list, x: 0, y: 0, color: .white)
        list.reset()
        let large = fonts.draw("Hi 你好", size: 32, rasterScale: 2, into: list, x: 0, y: 0, color: .white)
        XCTAssertEqual(large, small * 2, accuracy: 3)
        list.reset()
        let again = fonts.draw("Hi 你好", size: 16, into: list, x: 0, y: 0, color: .white)
        XCTAssertEqual(again, small, accuracy: 0.01)
        XCTAssertTrue(list.batches.allSatisfy { $0.textureID == 1 })
        XCTAssertGreaterThan(list.vertices.count, 0)
        XCTAssertTrue(list.vertices.allSatisfy { $0.posX.isFinite && $0.posY.isFinite })
    }

    func testDirtyRegionsBecomeEmptyWhenExistingGlyphsAreReused() throws {
        let fonts = try collection()
        fonts.atlas.markClean()
        let list = DrawList()
        fonts.draw("A", size: 16, into: list, x: 0, y: 0, color: .white)
        let first = try XCTUnwrap(fonts.atlas.dirtyUploadPayload())
        XCTAssertEqual(first.pixels.count, first.region.width * first.region.height)
        XCTAssertTrue(first.pixels.contains { $0 > 0 })
        XCTAssertLessThan(first.pixels.count, fonts.atlas.atlasWidth * fonts.atlas.atlasHeight)
        fonts.atlas.markClean()
        list.reset()
        fonts.draw("A", size: 16, into: list, x: 0, y: 0, color: .white)
        XCTAssertNil(fonts.atlas.dirtyUploadPayload())
        fonts.draw("字", size: 16, into: list, x: 20, y: 0, color: .white)
        XCTAssertNotNil(fonts.atlas.dirtyUploadPayload())
    }
}
