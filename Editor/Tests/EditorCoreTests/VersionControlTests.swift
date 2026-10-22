@testable import EditorCore
import Foundation
import PluginRuntime
import Testing

/// A bundled version control plugin behind the editor's own driver. Requests
/// carry recorded output, so parsing and paging run in the real Component
/// without the command-line tool.
private struct ProviderHarness {
    let plugin: VersionControlPlugin

    init(_ system: VersionControlSystem) throws {
        let provider = try #require(VersionControlProvider.provider(for: system))
        let client = PluginHostProcessClient(executableURL: try #require(EditorPluginHostLocator.resolve()))
        plugin = VersionControlPlugin(provider: provider,
                                      tool: VersionControlTool(executable: URL(fileURLWithPath: "/usr/bin/false"), environment: [:]),
                                      workspace: FileManager.default.temporaryDirectory, client: client)
    }

    /// One step, as the plugin answers it.
    func step(_ request: [String: Any]) throws -> [String: Any] {
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        return try #require(try JSONSerialization.jsonObject(with: plugin.invoke(encoded, stdout: "")) as? [String: Any])
    }

    /// An operation's result given its command's output, paged in `window`-byte windows.
    func parse<T: Decodable>(_ operation: String, _ stdout: String, window: Int = VersionControlPlugin.window,
                             as type: T.Type) async throws -> T {
        guard case let .result(data) = try await plugin.perform(["op": operation], resuming: ("parse", Data(stdout.utf8)),
                                                                baseWindow: window) else {
            throw VersionControlError.unsupported("not a JSON result")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private let porcelain = [
    "# branch.oid 1234", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -1",
    "1 M. N... 100644 100644 100644 aaa bbb Sources/App.swift",
    "1 .M N... 100644 100644 100644 aaa bbb README.md",
    "1 MM N... 100644 100644 100644 aaa bbb Notes/Draft one.md",
    "2 R. N... 100644 100644 100644 aaa bbb R100 Docs/New.md", "Docs/Old.md",
    "u UU N... 100644 100644 100644 100644 aaa bbb ccc Conflict.txt",
    "? Untracked.txt", "? Ünïcödé 🥭.md",
].joined(separator: "\0") + "\0"

private let loreStatus = """
    {"tagName":"repositoryStatusFile","data":{"path":"Art/Hero.png","size":10,"action":"keep","type":"file","flagStaged":false,"flagDirty":true,"flagConflict":false,"flagConflictUnresolved":false,"fromPath":""}}
    {"tagName":"repositoryStatusFile","data":{"path":"Docs/Plan.md","size":3,"action":"add","type":"file","flagStaged":true,"flagConflict":false,"flagConflictUnresolved":false,"fromPath":""}}
    {"tagName":"repositoryStatusRevision","data":{"branchName":"main","revisionLocalNumber":7,"revisionRemoteNumber":5,"isLocalAhead":1,"isRemoteAhead":0,"remoteBranchExist":1}}
    {"tagName":"repositoryStatusFile","data":{"path":"Docs/New.md","action":"move","type":"file","flagStaged":true,"fromPath":"Docs/Old.md"}}
    {"tagName":"repositoryStatusFile","data":{"path":"Docs","action":"keep","type":"directory","flagStaged":false}}
    {"tagName":"repositoryStatusFile","data":{"path":"Level.map","size":4294967296,"modified":1.5e9,"action":"keep","type":"file","flagConflict":true,"flagConflictUnresolved":true}}
    not json
    """

@Suite("Version control plugins", .timeLimit(.minutes(2)))
struct VersionControlTests {
    @Test func bundledPackagesContributeTheirSystems() throws {
        #expect(VersionControlProvider.bundled.map(\.system) == [.lore, .git])
        for provider in VersionControlProvider.bundled {
            let package = try PluginPackageLoader().load(at: provider.package)
            #expect(package.manifest.contributes.versionControl == provider.contribution)
            #expect(package.manifest.host.processes.first?.entryPoints == ["provider"])
        }
        #expect(VersionControlSystem.git.title == "Git")
        #expect(VersionControlProvider.provider(for: .lore)?.contribution.ignoreFile == ".loreignore")
    }

    @Test(arguments: [VersionControlPlugin.window, 64, 7])
    func gitPorcelainStatusParsesBranchAndEveryEntryKind(window: Int) async throws {
        let status = try await ProviderHarness(.git).parse("status", porcelain, window: window, as: StatusWire.self).model
        #expect(status.tracking == VersionControlTracking(branch: "main", upstream: "origin/main", ahead: 2, behind: 1))
        #expect(status.changes == [
            VersionControlChange(path: "Sources/App.swift", state: .modified, isStaged: true),
            VersionControlChange(path: "README.md", state: .modified, isStaged: false),
            VersionControlChange(path: "Notes/Draft one.md", state: .modified, isStaged: true),
            VersionControlChange(path: "Notes/Draft one.md", state: .modified, isStaged: false),
            VersionControlChange(path: "Docs/New.md", originalPath: "Docs/Old.md", state: .renamed, isStaged: true),
            VersionControlChange(path: "Conflict.txt", state: .conflicted, isStaged: false),
            VersionControlChange(path: "Untracked.txt", state: .untracked, isStaged: false),
            VersionControlChange(path: "Ünïcödé 🥭.md", state: .untracked, isStaged: false),
        ])
    }

    @Test func gitLogBranchesAndBranchNamesParse() async throws {
        let git = try ProviderHarness(.git)
        let log = try await git.parse("history", "abc\u{1f}Ada\u{1f}1700000000\u{1f}Add outline\u{1e}\ndef\u{1f}Lin\u{1f}1690000000\u{1f}Init\u{1e}",
                                      window: 16, as: [RevisionWire].self).map(\.model)
        #expect(log.map(\.id) == ["abc", "def"])
        #expect(log.first?.summary == "Add outline")
        #expect(log.first?.date == Date(timeIntervalSince1970: 1_700_000_000))
        let branches = try await git.parse("branches",
            "*\u{1f}refs/heads/main\n \u{1f}refs/heads/draft\n \u{1f}refs/remotes/origin/HEAD\n \u{1f}refs/remotes/origin/main\n",
            window: 10, as: [BranchWire].self).map(\.model)
        #expect(branches == [VersionControlBranch(name: "main", isCurrent: true), VersionControlBranch(name: "draft", isCurrent: false),
                             VersionControlBranch(name: "origin/main", isCurrent: false, isRemote: true)])
        #expect(try await git.parse("history", "", as: [RevisionWire].self).isEmpty)
        for name in ["-bad", "a..b", "with space", "tilde~1"] {
            #expect(try git.step(["op": "create-branch", "name": name])["error"] != nil)
        }
        #expect((try git.step(["op": "create-branch", "name": "draft/two"])["run"] as? [String]) == ["switch", "--quiet", "--create", "draft/two"])
    }

    @Test func gitPathListsTravelOnStandardInput() throws {
        let paths = (0..<20_000).map { "Assets/Level \($0)/Texture.png" }
        let step = try ProviderHarness(.git).step(["op": "stage", "paths": paths])
        #expect((step["run"] as? [String])?.contains("--pathspec-from-file=-") == true)
        #expect(step["input"] as? String == paths.joined(separator: "\0"))
        #expect((step["env"] as? [String: String])?["GIT_TERMINAL_PROMPT"] == "0")
    }

    /// Far past what one call could parse: the driver pages it.
    @Test func largeStatusOutputIsPaged() async throws {
        let records = (0..<50_000).map { "1 .M N... 100644 100644 100644 aaa bbb Assets/Generated/File \($0).txt" }
        let status = try await ProviderHarness(.git).parse("status", records.joined(separator: "\0") + "\0", as: StatusWire.self)
        #expect(status.changes.count == 50_000)
        #expect(status.changes.last?.path == "Assets/Generated/File 49999.txt")
    }

    @Test(arguments: [VersionControlPlugin.window, 32])
    func loreJSONEventsParseStatusBranchesAndLocks(window: Int) async throws {
        let lore = try ProviderHarness(.lore)
        let status = try await lore.parse("status", loreStatus, window: window, as: StatusWire.self).model
        #expect(status.tracking == VersionControlTracking(branch: "main", upstream: "main", ahead: 2, behind: 0))
        #expect(status.changes == [
            VersionControlChange(path: "Art/Hero.png", state: .modified, isStaged: false),
            VersionControlChange(path: "Docs/Plan.md", state: .added, isStaged: true),
            VersionControlChange(path: "Docs/New.md", originalPath: "Docs/Old.md", state: .renamed, isStaged: true),
            VersionControlChange(path: "Level.map", state: .conflicted, isStaged: false),
        ])
        #expect(try await lore.parse("history", "12 Add hero art\n11 Init\n", window: window, as: [RevisionWire].self).map(\.model) == [
            VersionControlRevision(id: "12", summary: "Add hero art"), VersionControlRevision(id: "11", summary: "Init"),
        ])
        let branches = try await lore.parse("branches", """
            {"tagName":"branchListEntry","data":{"location":"local","name":"main","isCurrent":true}}
            {"tagName":"branchListEntry","data":{"location":"remote","name":"main","isCurrent":false}}
            {"tagName":"branchListEntry","data":{"location":"remote","name":"art","isCurrent":false}}
            """, window: window, as: [BranchWire].self).map(\.model)
        #expect(branches == [VersionControlBranch(name: "main", isCurrent: true), VersionControlBranch(name: "art", isCurrent: false, isRemote: true)])
        #expect(try await lore.parse("locks", #"{"tagName":"lockFileStatus","data":{"path":"Art/Hero.png","owner":"ada","lockedAt":1}}"#,
                                     window: window, as: [String].self) == ["Art/Hero.png"])
    }

    @Test func loreSplitsLongPathListsAndValidatesRemotes() throws {
        let lore = try ProviderHarness(.lore)
        let paths = (0..<100).map { "Art/Hero \($0).png" }
        let first = try lore.step(["op": "stage", "paths": paths])
        #expect((first["run"] as? [String])?.first == "stage")
        #expect((first["run"] as? [String])?.count == 65)
        #expect(first["next"] as? String == "64")
        let second = try lore.step(["op": "stage", "paths": paths, "next": "64", "output": ["exit": 0, "stderr": ""]])
        #expect((second["run"] as? [String]).map { Array($0.dropFirst()) } == Array(paths.dropFirst(64)))
        let done = try lore.step(["op": "stage", "paths": paths, "next": "100", "output": ["exit": 0, "stderr": ""]])
        #expect(done.keys.contains("result"))
        let failed = try lore.step(["op": "stage", "paths": paths, "next": "64", "output": ["exit": 1, "stderr": "offline\n"]])
        #expect(failed["error"] as? String == "offline")
        #expect(try lore.step(["op": "init", "remote": "https://example.com"])["error"] != nil)
        #expect((try lore.step(["op": "init", "remote": "lore://studio:4100/game"])["run"] as? [String])
            == ["repository", "create", "lore://studio:4100/game"])
    }

    @Test func detectionPrefersTheNearestWorkingTreeAndLoreOverGit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcs-detect-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Game/Project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(VersionControlProvider.repository(containing: project)?.system == .git)
        #expect(VersionControlProvider.repository(containing: project)?.root.lastPathComponent == root.lastPathComponent)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Game/.lore"), withIntermediateDirectories: true)
        #expect(VersionControlProvider.repository(containing: project)?.system == .lore)
    }

    @Test @MainActor func gitWorkingTreeRoundTripsThroughThePlugin() async throws {
        guard let git = VersionControlTool.locate("git") else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcs-git-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = EditorVersionControl(projectRoot: root, pluginHost: EditorPluginHostLocator.resolve())
        await model.refresh()
        #expect(model.snapshot.availability == .noRepository)
        #expect(model.snapshot.installedSystems.contains(.git))

        await model.initialize(.git)
        #expect(model.snapshot.error == nil)
        #expect(model.snapshot.repository?.system == .git)
        // Commits need an identity; keep it local to this repository.
        for (key, value) in [("user.name", "Guava Tests"), ("user.email", "tests@guava.invalid")] {
            let process = Process()
            process.executableURL = git.executable
            process.arguments = ["config", key, value]
            process.currentDirectoryURL = root
            try process.run()
            process.waitUntilExit()
        }

        try "# Chapter One\n".write(to: root.appendingPathComponent("Chapter.md"), atomically: true, encoding: .utf8)
        await model.refresh()
        // Initializing ignores the editor's machine-local state.
        let ignore = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(EditorVersionControl.machineStatePatterns.allSatisfy(ignore.contains))
        #expect(model.snapshot.unstaged == [VersionControlChange(path: ".gitignore", state: .untracked, isStaged: false),
                                            VersionControlChange(path: "Chapter.md", state: .untracked, isStaged: false)])
        #expect(model.projectFileStates["Chapter.md"] == .untracked)
        let chapter = try #require(model.snapshot.unstaged.first { $0.path == "Chapter.md" })
        #expect(await model.diff(chapter).contains("+# Chapter One"))
        // The diff tab follows the file into the staged area and outlives its change.
        await model.compare(chapter)
        #expect(model.snapshot.comparison?.diff?.contains("+# Chapter One") == true)

        await model.stage(model.snapshot.unstaged)
        #expect(model.snapshot.comparison?.change.isStaged == true)
        #expect(model.snapshot.staged.map(\.state) == [.added, .added])
        await model.unstage(model.snapshot.staged.filter { $0.path == ".gitignore" })
        #expect(model.snapshot.staged.map(\.path) == ["Chapter.md"])
        #expect(await model.commit(message: "Add chapter one\n\nWith a body that \"quotes\" and -dashes."))
        #expect(model.snapshot.status.changes.map(\.path) == [".gitignore"])
        #expect(model.snapshot.history.first?.summary == "Add chapter one")
        #expect(model.snapshot.comparison?.isCurrent == false)
        model.endComparison()
        #expect(model.snapshot.branches.contains { $0.isCurrent })

        try "# Chapter One\nRevised.\n".write(to: root.appendingPathComponent("Chapter.md"), atomically: true, encoding: .utf8)
        await model.refresh()
        let revised = try #require(model.snapshot.unstaged.first { $0.path == "Chapter.md" })
        #expect(revised.state == .modified)
        #expect(await model.diff(revised).contains("+Revised."))
        await model.discard([revised])
        #expect(try String(contentsOf: root.appendingPathComponent("Chapter.md"), encoding: .utf8) == "# Chapter One\n")

        await model.createBranch("draft")
        #expect(model.snapshot.status.tracking.branch == "draft")
        await model.createBranch("-bad")
        #expect(model.snapshot.error?.contains("not a valid branch name") == true)
        #expect(!(await model.commit(message: "   ")))
        #expect(model.snapshot.error != nil)
        await model.setLocked(true, paths: ["Chapter.md"])
        #expect(model.snapshot.error == "Git does not lock files.")
    }
}

@Test func documentWorkspaceCreatesRenamesAndTrashesFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("docs-files-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let documents = EditorDocumentWorkspace(root: root)
    #expect(documents.create("Notes/Idea.md", text: "# Idea\n"))
    #expect(documents.selectedPath == "Notes/Idea.md")
    #expect(!documents.create("Notes/Idea.md"))
    #expect(documents.move("Notes", to: "Drafts"))
    #expect(documents.selectedPath == "Drafts/Idea.md")
    #expect(try String(contentsOf: root.appendingPathComponent("Drafts/Idea.md"), encoding: .utf8) == "# Idea\n")
    // Removal goes through the user's Trash, so it is not exercised here.
    documents.edit("Drafts/Idea.md", text: "Unsaved")
    #expect(!documents.move("Drafts", to: "Archive"))
}

extension VersionControlTests {
    @Test @MainActor func disabledSystemsAreNotDetected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcs-off-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = EditorVersionControl(projectRoot: root, pluginHost: EditorPluginHostLocator.resolve())
        await model.setEnabled(false, system: .git)
        #expect(model.snapshot.disabledSystems == [.git])
        #expect(model.snapshot.availability == .noRepository)
        await model.setEnabled(true, system: .git)
        #expect(model.snapshot.disabledSystems.isEmpty)
        #expect(model.snapshot.repository?.system == .git)
    }
}
