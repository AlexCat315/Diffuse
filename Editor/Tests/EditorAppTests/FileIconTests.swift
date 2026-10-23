@testable import EditorUI
import Testing

@Suite("File icons")
struct FileIconTests {
    @Test("Common files map to their language and icon; whole names win over extensions")
    func mapping() {
        let expected: [(String, String, String)] = [
            ("Scripts/Player.swift", "Swift", "swift"),
            ("notes.txt", "Plain Text", "text"),
            ("docs/guide.md", "Markdown", "markdown"),
            ("paper.tex", "LaTeX", "latex"),
            ("README.md", "Markdown", "readme"), ("LICENSE", "Plain Text", "license"),
            ("Makefile", "Makefile", "makefile"), ("CMakeLists.txt", "CMake", "cmake"),
            ("package.json", "JSON", "package-json"),
            ("textures/albedo.png", "Image", "image"),
            ("models/hero.glb", "3D Model", "3d"), (".gitignore", "Git", "git"),
            ("data.bin", "Binary", "binary"),
            ("unknown.qqq", "QQQ", "file"), ("NOEXTENSION", "Plain Text", "text"),
        ]
        for (path, name, icon) in expected {
            let kind = DocumentKind(path: path)
            #expect(kind.name == name, "\(path)")
            #expect(kind.iconKey == icon, "\(path)")
        }
    }

    @Test("Every icon a path can resolve to ships in both the dark and light variant")
    func everyIconIsBundled() {
        let paths = ["a.swift", "a.md", "a.txt", "a.tex", "a.svg", "a.png", "a.mp4", "a.wav", "a.ttf", "a.glb",
                     "a.pdf", "a.zip", "a.bin", "a.exe", "a.db", "a.qqq", "README", "LICENSE",
                     "Makefile", "CMakeLists.txt", "Dockerfile", "package.json", "Package.resolved",
                     ".gitignore", ".env", ".npmrc", "build.ninja", "build.gradle"]
        let keys = Set(paths.map { DocumentKind(path: $0).iconKey }).union(["folder", "folder_open"])
        for key in keys {
            for suffix in ["", "-light"] {
                #expect(EditorAppResourceBundle.bundle.url(forResource: "filetype-\(key)\(suffix)",
                                                          withExtension: "svg") != nil, "filetype-\(key)\(suffix)")
            }
        }
    }
}
