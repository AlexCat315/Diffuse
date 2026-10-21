internal import GuavaUI
internal import GuavaUIRuntime

/// What a document path looks like to the user: a language name and a file
/// icon. Derived on demand from the file name; nothing here is stored. Whole
/// file names (README, Makefile, package.json…) win over extensions, the way
/// mature editors recognise them.
struct DocumentKind {
    let name: String
    /// A `filetype-<key>` icon in Resources/FileIcons.
    let iconKey: String

    init(path: String) {
        let fileName = path.split(separator: "/").last.map(String.init) ?? path
        let lower = fileName.lowercased()
        if let special = Self.fileNames[lower] ?? Self.prefixes.first(where: { lower.hasPrefix($0.0) })?.1 {
            self = special
            return
        }
        let ext = fileName.contains(".") ? fileName.split(separator: ".").last.map { $0.lowercased() } ?? "" : ""
        self = Self.extensions[ext] ?? (ext.isEmpty ? Self("Plain Text", "text") : Self(ext.uppercased(), "file"))
    }

    private init(_ name: String, _ iconKey: String) {
        self.name = name
        self.iconKey = iconKey
    }

    var isMarkdown: Bool { name == "Markdown" }

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
        ("readme", .init("Markdown", "readme")),
        ("license", .init("Plain Text", "license")), ("licence", .init("Plain Text", "license")),
        ("build.gradle", .init("Gradle", "gradle")),
    ]

    private static let extensions: [String: DocumentKind] = {
        var table: [String: DocumentKind] = [:]
        func add(_ name: String, _ icon: String, _ extensions: String...) {
            for ext in extensions { table[ext] = .init(name, icon) }
        }
        add("Swift", "swift", "swift")
        add("C", "c", "c"); add("C", "c-header", "h")
        add("C++", "cpp", "cc", "cpp", "cxx", "mm"); add("C++", "cpp-header", "hpp", "hh", "hxx")
        add("Objective-C", "c", "m")
        add("C#", "csharp", "cs")
        add("Java", "java", "java"); add("Kotlin", "kotlin", "kt", "kts")
        add("Python", "python", "py", "pyi")
        add("JavaScript", "javascript", "js", "mjs", "cjs", "jsx")
        add("TypeScript", "typescript", "ts", "mts", "cts", "tsx")
        add("Rust", "rust", "rs"); add("Go", "go", "go"); add("Lua", "lua", "lua")
        add("Ruby", "ruby", "rb"); add("PHP", "php", "php"); add("Dart", "dart", "dart")
        add("Zig", "zig", "zig"); add("Scala", "scala", "scala"); add("Haskell", "haskell", "hs")
        add("Assembly", "assembly", "s", "asm")
        add("Shell", "bash", "sh", "bash", "zsh", "fish")
        add("PowerShell", "powershell", "ps1"); add("Batch", "batch", "bat", "cmd")
        add("Shader", "shader", "glsl", "hlsl", "metal", "wgsl", "vert", "frag", "comp", "shader")
        add("Markdown", "markdown", "md", "markdown")
        add("Plain Text", "text", "txt"); add("Log", "log", "log")
        add("JSON", "json", "json", "jsonc", "json5"); add("YAML", "yaml", "yml", "yaml")
        add("TOML", "toml", "toml"); add("XML", "xml", "xml", "plist", "xib", "storyboard")
        add("HTML", "html", "html", "htm"); add("CSS", "css", "css", "scss", "less")
        add("CSV", "csv", "csv", "tsv")
        add("Properties", "properties", "properties"); add("INI", "config", "ini", "cfg", "conf")
        add("Lock", "lock", "lock")
        add("CMake", "cmake", "cmake"); add("Gradle", "gradle", "gradle")
        add("SVG", "svg", "svg")
        add("Image", "image", "png", "jpg", "jpeg", "gif", "webp", "bmp", "tga", "exr", "hdr", "ktx", "dds", "ico")
        add("Video", "video", "mp4", "mov", "mkv", "webm", "avi")
        add("Audio", "audio", "wav", "mp3", "ogg", "flac", "aac", "m4a")
        add("Font", "font", "ttf", "otf", "woff", "woff2")
        add("3D Model", "3d", "gltf", "glb", "fbx", "obj", "usd", "usda", "usdz", "blend")
        add("PDF", "pdf", "pdf")
        add("Archive", "zip", "zip", "tar", "gz", "7z", "rar", "xz")
        add("Binary", "binary", "bin", "dat", "o", "a", "dylib", "so", "wasm")
        add("Executable", "exe", "exe", "dll", "app")
        add("Database", "database", "db", "sqlite", "sql")
        add("LaTeX", "latex", "tex"); add("Protocol Buffers", "proto", "proto"); add("GraphQL", "graphql", "graphql", "gql")
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
            let key = isFolder ? (isOpen ? "folder_open" : "folder") : DocumentKind(path: path).iconKey
            return Image(resource: .svg(named: "filetype-\(key)" + (isDark ? "" : "-light"),
                                        in: EditorAppResourceBundle.bundle, subdirectory: "FileIcons"),
                         width: size, height: size, contentMode: .fit, renderingMode: .color)
                .accessibilityHidden()
        }
    }
}
