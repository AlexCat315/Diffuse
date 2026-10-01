import Foundation

public enum EditorProjectTemplate: String, Codable, Sendable {
    case blank
    case crystalRush
}

public struct EditorProjectDescriptor: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let name: String
    public let template: EditorProjectTemplate
    public let createdAt: Date

    public init(name: String, template: EditorProjectTemplate) {
        schemaVersion = 1
        id = UUID()
        self.name = name
        self.template = template
        createdAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    }
}

public struct EditorProjectLocation: Sendable {
    public let directory: URL
    public let descriptor: EditorProjectDescriptor?
    public var name: String { descriptor?.name ?? directory.lastPathComponent }
}

public enum EditorProjectLifecycle {
    public static let descriptorPath = ".guava/project.json"
    public static let scenePath = ".guava/editor-scene-manifest.json"

    /// Creates a new child of the chosen parent. Existing directories are never adopted or overwritten.
    public static func create(name: String, parent: URL,
                              template: EditorProjectTemplate = .blank) throws -> EditorProjectLocation {
        let name = try validatedName(name)
        let manager = FileManager.default
        let parent = parent.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure("The project location must be an existing folder.")
        }
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        guard !manager.fileExists(atPath: destination.path) else {
            throw Failure("A file or folder with this project name already exists.")
        }
        let staging = parent.appendingPathComponent(".guava-create-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        for folder in [".guava", "Assets", "Scripts"] {
            try manager.createDirectory(at: staging.appendingPathComponent(folder), withIntermediateDirectories: false)
        }
        let descriptor = EditorProjectDescriptor(name: name, template: template)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(descriptor).write(to: staging.appendingPathComponent(descriptorPath), options: .atomic)
        switch template {
        case .blank:
            let scene = EditorSceneManifest(revision: 0, entityCount: 0, roots: [])
            try encoder.encode(scene).write(to: staging.appendingPathComponent(scenePath), options: .atomic)
        case .crystalRush:
            try copyTemplate("crystal-rush.swift", extension: "txt", to: staging.appendingPathComponent("Scripts/CrystalRush.swift"))
            try copyTemplate("crystal-rush.scene", extension: "json", to: staging.appendingPathComponent(scenePath))
            try copyTemplate("crystal-rush.script-assets", extension: "json", to: staging.appendingPathComponent(".guava/script-assets.json"))
            try copyTemplate("crystal-rush.readme", extension: "txt", to: staging.appendingPathComponent("README.md"))
        }
        // Rename only after every file has been written and validated. A collision at this point also fails safely.
        _ = try inspect(staging)
        try manager.moveItem(at: staging, to: destination)
        return EditorProjectLocation(directory: destination, descriptor: descriptor)
    }

    /// Read-only validation before EditorApplication creates caches, history, or script services.
    /// Older projects with a .guava directory remain supported, including empty legacy projects.
    public static func inspect(_ directory: URL, validateScene: Bool = true) throws -> EditorProjectLocation {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure("The project folder no longer exists.")
        }
        let guava = directory.appendingPathComponent(".guava", isDirectory: true)
        guard manager.fileExists(atPath: guava.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure("This folder is not a Guava project. Choose its project root or create a new project.")
        }
        guard try guava.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw Failure("The project's .guava folder must not be a symbolic link.")
        }
        var descriptor: EditorProjectDescriptor?
        let descriptorURL = directory.appendingPathComponent(descriptorPath)
        if manager.fileExists(atPath: descriptorURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            descriptor = try decoder.decode(EditorProjectDescriptor.self, from: Data(contentsOf: descriptorURL))
            guard descriptor?.schemaVersion == 1 else {
                throw Failure("This project uses an unsupported project format.")
            }
        }
        let sceneURL = directory.appendingPathComponent(scenePath)
        if validateScene, manager.fileExists(atPath: sceneURL.path) {
            let scene = try JSONDecoder().decode(EditorSceneManifest.self, from: Data(contentsOf: sceneURL))
            guard scene.schemaVersion == EditorSceneManifest.currentSchemaVersion else {
                throw Failure("This project uses an unsupported scene format.")
            }
            var ids = Set<UInt64>()
            func check(_ node: EditorSceneManifestNode) throws {
                guard ids.insert(node.id).inserted else { throw Failure("The saved scene contains duplicate entity IDs.") }
                for child in node.children { try check(child) }
            }
            for root in scene.roots { try check(root) }
            guard ids.count == scene.entityCount else { throw Failure("The saved scene has an invalid entity count.") }
        }
        return EditorProjectLocation(directory: directory, descriptor: descriptor)
    }

    /// Recoverable deletion. Never recursively delete an arbitrary recent-list path.
    public static func moveToTrash(_ directory: URL) throws -> URL {
        // Trash must remain available even if a managed project has a corrupt scene.
        let location = try inspect(directory, validateScene: false)
        let root = location.directory
        let protected = [URL(fileURLWithPath: "/"), FileManager.default.homeDirectoryForCurrentUser,
                         FileManager.default.temporaryDirectory].map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        guard !protected.contains(root.path) else { throw Failure("This folder cannot be deleted as a project.") }
        guard location.descriptor != nil else {
            throw Failure("Legacy projects can only be removed from Recents. Manage their files in the file manager.")
        }
        #if os(macOS)
        var trashed: NSURL?
        try FileManager.default.trashItem(at: root, resultingItemURL: &trashed)
        return (trashed as URL?) ?? root
        #else
        // A recoverable application trash is used where Foundation has no native trash API.
        let trash = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Guava/DeletedProjects", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let destination = trash.appendingPathComponent("\(root.lastPathComponent)-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: root, to: destination)
        return destination
        #endif
    }

    public static func validatedName(_ proposed: String) throws -> String {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
              name.count <= 100, !name.hasSuffix("."), name.rangeOfCharacter(from: invalid) == nil else {
            throw Failure("Enter a valid project name (no path separators or special characters).")
        }
        return name
    }

    private static func copyTemplate(_ name: String, extension ext: String, to destination: URL) throws {
        guard let source = EditorCoreResourceBundle.bundle.url(forResource: name, withExtension: ext) else {
            throw Failure("The bundled example project is missing. Reinstall the editor.")
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public struct Failure: LocalizedError, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { L(message) }
    }
}
