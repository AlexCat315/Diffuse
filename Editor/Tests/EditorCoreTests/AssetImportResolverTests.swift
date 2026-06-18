@testable import EditorCore
import Foundation
import Testing

@Suite("AssetImportResolver", .serialized)
struct AssetImportResolverTests {

    private func makeTempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("guava-import-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? contents.data(using: .utf8)!.write(to: url)
    }

    @Test("glb is self-contained")
    func glbSelfContained() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let glb = dir.appendingPathComponent("prop.glb")
        write("binary", to: glb)

        let resolved = AssetImportResolver.resolve(glb)
        #expect(resolved.map(\.relativePath) == ["prop.glb"])
    }

    @Test("gltf pulls its .bin buffer and subfolder textures")
    func gltfDependencies() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gltf = dir.appendingPathComponent("lighter.gltf")
        write("""
        {
          "buffers": [{ "uri": "lighter.bin" }],
          "images": [
            { "uri": "textures/diff.jpg" },
            { "uri": "textures/diff.jpg" },
            { "uri": "data:image/png;base64,AAAA" },
            { "uri": "https://example.com/remote.png" }
          ]
        }
        """, to: gltf)

        let relatives = AssetImportResolver.resolve(gltf).map(\.relativePath)
        // Asset first, then deduped external deps; embedded/remote skipped.
        #expect(relatives == ["lighter.gltf", "lighter.bin", "textures/diff.jpg"])
    }

    @Test("obj resolves mtllib and its texture maps, stripping map options")
    func objMtlTextures() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let obj = dir.appendingPathComponent("crate.obj")
        write("""
        mtllib crate.mtl
        v 0 0 0
        f 1 1 1
        """, to: obj)
        write("""
        newmtl crate
        map_Kd -o 1 1 -s 2 2 textures/crate_diff.png
        map_Bump textures/crate_nrm.png
        """, to: dir.appendingPathComponent("crate.mtl"))

        let relatives = AssetImportResolver.resolve(obj).map(\.relativePath)
        #expect(relatives == ["crate.obj", "crate.mtl",
                              "textures/crate_diff.png", "textures/crate_nrm.png"])
    }

    @Test("textures referenced by an .mtl in a subfolder stay relative to it")
    func mtlInSubfolder() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let obj = dir.appendingPathComponent("statue.obj")
        write("mtllib mats/statue.mtl\n", to: obj)
        write("map_Kd wood.png\n", to: dir.appendingPathComponent("mats/statue.mtl"))

        let relatives = AssetImportResolver.resolve(obj).map(\.relativePath)
        #expect(relatives == ["statue.obj", "mats/statue.mtl", "mats/wood.png"])
    }

    @Test("path-escaping references are rejected")
    func rejectsEscapingPaths() {
        #expect(AssetImportResolver.sanitizedRelativePath("../secret.png") == nil)
        #expect(AssetImportResolver.sanitizedRelativePath("/etc/passwd") == nil)
        #expect(AssetImportResolver.sanitizedRelativePath("C:/Windows/system32") == nil)
        #expect(AssetImportResolver.sanitizedRelativePath("./textures/ok.png") == "textures/ok.png")
        #expect(AssetImportResolver.sanitizedRelativePath("buf.bin") == "buf.bin")
    }

    @Test("supported-format gate")
    func supportedFormats() {
        #expect(AssetImportResolver.isSupported(URL(fileURLWithPath: "a/model.gltf")))
        #expect(AssetImportResolver.isSupported(URL(fileURLWithPath: "a/model.GLB")))
        #expect(AssetImportResolver.isSupported(URL(fileURLWithPath: "a/model.obj")))
        #expect(AssetImportResolver.isSupported(URL(fileURLWithPath: "a/smoke.png")))
        #expect(AssetImportResolver.isSupported(URL(fileURLWithPath: "a/smoke.WEBP")))
        #expect(AssetImportResolver.isSupported(URL(fileURLWithPath: "a/vector.svg")))
        #expect(!AssetImportResolver.isSupported(URL(fileURLWithPath: "a/model.blend")))
        #expect(!AssetImportResolver.isSupported(URL(fileURLWithPath: "a/archive.zip")))
    }

    @Test("texture import is self-contained")
    func textureSelfContained() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let texture = dir.appendingPathComponent("smoke.png")
        write("image", to: texture)

        let resolved = AssetImportResolver.resolve(texture)
        #expect(resolved.map(\.relativePath) == ["smoke.png"])
    }
}
