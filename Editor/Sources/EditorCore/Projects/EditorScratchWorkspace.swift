import Foundation

/// The workspace a window falls back to when it has no project.
///
/// Everything the editor does — panels, the script workspace, the agent's file
/// tools, autosave — is rooted in a project directory, so "no project" cannot
/// mean "no directory". This is a real project folder in Application Support:
/// the workbench and the agent both work in it without the user choosing one
/// first, and whatever they save there survives to the next launch.
///
/// It is deliberately never written to the saved project list, so the next
/// launch restores the user's real projects instead of reopening this one.
public enum EditorScratchWorkspace {
    /// Stable location, so a scratch session keeps what it saved last time.
    public static func directory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cove", isDirectory: true)
            .appendingPathComponent("Untitled", isDirectory: true)
    }

    /// Canonical form, matching how the project list and launcher compare paths.
    public static func canonicalPath() -> String {
        directory().standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func isScratch(_ path: String) -> Bool {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
            == canonicalPath()
    }

    /// Creates the folder when it is missing and makes sure it is a valid
    /// project, so `EditorApplication` can open it like any other.
    public static func prepare() throws -> EditorProjectLocation {
        let directory = directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try EditorProjectLifecycle.adopt(directory)
    }
}
