internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime

/// What a document path looks like to the user: a language name and a file
/// icon. Derived on demand from the file name; nothing here is stored. Whole
/// file names (README, Makefile, package.json…) win over extensions, the way
/// mature editors recognise them. Languages themselves come from plugin
/// contributions, never from a table here.
struct DocumentKind {
    let name: String
    /// A `filetype-<key>` icon in Resources/FileIcons.
    let iconKey: String
    /// The contributed language's identifier, when one claims the path.
    let languageID: String?

    init(path: String, languages: LanguageCatalog = .bundled) {
        let fileName = path.split(separator: "/").last.map(String.init) ?? path
        let lower = fileName.lowercased()
        if let special = Self.fileNames[lower] ?? Self.prefixes.first(where: { lower.hasPrefix($0.0) })?.1 {
            self = special
            return
        }
        let ext = fileName.contains(".") ? fileName.split(separator: ".").last.map { $0.lowercased() } ?? "" : ""
        if let language = languages.descriptor(forExtension: ext) {
            self = Self(language.title, language.iconKey, languageID: language.id)
        } else if let file = Self.fileKinds[ext] {
            self = file
        } else {
            self = ext.isEmpty ? Self("Plain Text", "text") : Self(ext.uppercased(), "file")
        }
    }

    private init(_ name: String, _ iconKey: String, languageID: String? = nil) {
        self.name = name
        self.iconKey = iconKey
        self.languageID = languageID
    }

    var isMarkdown: Bool { languageID == "markdown" }

    private static let fileNames: [String: DocumentKind] = [
        "makefile": .init("Makefile", "makefile"),
        "cmakelists.txt": .init("CMake", "cmake"),
        "dockerfile": .init("Dockerfile", "docker"),
        "package.json": .init("JSON", "package-json"),
        "package.resolved": .init("JSON", "lock"),
        ".gitignore": .init("Git", "git"), ".gitattributes": .init("Git", "git"), ".gitmodules": .init("Git", "git"),
        ".env": .init("Environment", "env"),
        ".npmrc": .init("npm", "npm"),
        "build.ninja": .init("Ninja", "ninja"),
    ]

    private static let prefixes: [(String, DocumentKind)] = [
        ("readme", .init("Markdown", "readme", languageID: "markdown")),
        ("license", .init("Plain Text", "license")), ("licence", .init("Plain Text", "license")),
        ("build.gradle", .init("Gradle", "gradle")),
    ]

    /// File types that are not text languages: their identity cannot come from
    /// a grammar or language server.
    private static let fileKinds: [String: DocumentKind] = {
        var table: [String: DocumentKind] = [:]
        func add(_ name: String, _ icon: String, _ extensions: String...) {
            for ext in extensions { table[ext] = .init(name, icon) }
        }
        add("Image", "image", "png", "jpg", "jpeg", "gif", "webp", "bmp", "tga", "exr", "hdr", "ktx", "dds", "ico")
        add("Video", "video", "mp4", "mov", "mkv", "webm", "avi")
        add("Audio", "audio", "wav", "mp3", "ogg", "flac", "aac", "m4a")
        add("Font", "font", "ttf", "otf", "woff", "woff2")
        add("3D Model", "3d", "gltf", "glb", "fbx", "obj", "usd", "usda", "usdz", "blend")
        add("PDF", "pdf", "pdf")
        add("Archive", "zip", "zip", "tar", "gz", "7z", "rar", "xz")
        add("Binary", "binary", "bin", "dat", "o", "a", "dylib", "so", "wasm")
        add("Executable", "exe", "exe", "dll", "app")
        add("Database", "database", "db", "sqlite")
        add("SVG", "svg", "svg")
        return table
    }()
}

/// A file or folder icon in its own colours (Catppuccin, MIT; see
/// Resources/FileIcons). The dark or light variant follows the theme.
struct FileIcon: View {
    let path: String
    var isFolder = false
    var isOpen = false
    var size: Float = 14

    var body: some View {
        ThemeReader { theme in
            let background = theme.colors.background
            let isDark = 0.2126 * background.r + 0.7152 * background.g + 0.0722 * background.b < 0.5
            let resource = isFolder ? (isOpen ? "folder_open" : "folder") : DocumentKind(path: path).iconKey
            let key = EditorAppResourceBundle.bundle.url(forResource: "filetype-\(resource)",
                                                         withExtension: "svg",
                                                         subdirectory: "FileIcons") != nil ? resource : "file"
            return Image(resource: .svg(named: "filetype-\(key)" + (isDark ? "" : "-light"),
                                        in: EditorAppResourceBundle.bundle, subdirectory: "FileIcons"),
                         width: size, height: size, contentMode: .fit, renderingMode: .color)
                .accessibilityHidden()
        }
    }
}
