internal import GuavaUI
internal import GuavaUIRuntime

/// What a document path looks like to the user: a language name and an icon.
/// Derived on demand from the extension; nothing here is stored.
struct DocumentKind {
    let name: String
    let icon: BundleImageResource

    init(path: String) {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let ext = name.contains(".") ? name.split(separator: ".").last.map { $0.lowercased() } ?? "" : ""
        switch ext {
        case "swift": self.init("Swift", UIIcons.File.fileCode)
        case "md", "markdown": self.init("Markdown", UIIcons.File.fileText)
        case "json": self.init("JSON", UIIcons.Editor.brackets)
        case "yml", "yaml": self.init("YAML", UIIcons.File.fileText)
        case "js", "mjs", "jsx": self.init("JavaScript", UIIcons.File.fileCode)
        case "ts", "tsx": self.init("TypeScript", UIIcons.File.fileCode)
        case "py": self.init("Python", UIIcons.File.fileCode)
        case "c", "h": self.init("C", UIIcons.File.fileCode)
        case "cc", "cpp", "hpp", "mm", "m": self.init("C++", UIIcons.File.fileCode)
        case "java", "kt": self.init(ext == "kt" ? "Kotlin" : "Java", UIIcons.File.fileCode)
        case "rs": self.init("Rust", UIIcons.File.fileCode)
        case "go": self.init("Go", UIIcons.File.fileCode)
        case "html", "css", "xml", "svg": self.init(ext.uppercased(), UIIcons.File.fileCode)
        case "sh", "zsh", "bash": self.init("Shell", UIIcons.Editor.terminal)
        case "txt", "": self.init(L("Plain Text"), UIIcons.File.fileText)
        default: self.init(ext.uppercased(), UIIcons.File.file)
        }
    }

    private init(_ name: String, _ icon: BundleImageResource) {
        self.name = name
        self.icon = icon
    }

    var isMarkdown: Bool { name == "Markdown" }
}
