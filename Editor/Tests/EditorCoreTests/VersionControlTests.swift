@testable import EditorCore
import Foundation
import Testing

@Test func gitPorcelainStatusParsesBranchAndEveryEntryKind() {
    let output = [
        "# branch.oid 1234", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -1",
        "1 M. N... 100644 100644 100644 aaa bbb Sources/App.swift",
        "1 .M N... 100644 100644 100644 aaa bbb README.md",
        "1 MM N... 100644 100644 100644 aaa bbb Notes/Draft one.md",
        "2 R. N... 100644 100644 100644 aaa bbb R100 Docs/New.md", "Docs/Old.md",
        "u UU N... 100644 100644 100644 100644 aaa bbb ccc Conflict.txt",
        "? Untracked.txt",
    ].joined(separator: "\0") + "\0"
    let status = GitBackend.parseStatus(output)
    #expect(status.tracking == VersionControlTracking(branch: "main", upstream: "origin/main", ahead: 2, behind: 1))
    #expect(status.changes == [
        VersionControlChange(path: "Sources/App.swift", state: .modified, isStaged: true),
        VersionControlChange(path: "README.md", state: .modified, isStaged: false),
        VersionControlChange(path: "Notes/Draft one.md", state: .modified, isStaged: true),
        VersionControlChange(path: "Notes/Draft one.md", state: .modified, isStaged: false),
        VersionControlChange(path: "Docs/New.md", originalPath: "Docs/Old.md", state: .renamed, isStaged: true),
        VersionControlChange(path: "Conflict.txt", state: .conflicted, isStaged: false),
        VersionControlChange(path: "Untracked.txt", state: .untracked, isStaged: false),
    ])
}

@Test func gitLogAndBranchesParse() {
    let log = GitBackend.parseLog("abc\u{1f}Ada\u{1f}1700000000\u{1f}Add outline\u{1e}\ndef\u{1f}Lin\u{1f}1690000000\u{1f}Init\u{1e}")
    #expect(log.map(\.id) == ["abc", "def"])
    #expect(log.first?.summary == "Add outline")
    #expect(log.first?.date == Date(timeIntervalSince1970: 1_700_000_000))
    let branches = GitBackend.parseBranches("*\u{1f}refs/heads/main\n \u{1f}refs/heads/draft\n \u{1f}refs/remotes/origin/HEAD\n \u{1f}refs/remotes/origin/main\n")
    #expect(branches == [VersionControlBranch(name: "main", isCurrent: true), VersionControlBranch(name: "draft", isCurrent: false),
                         VersionControlBranch(name: "origin/main", isCurrent: false, isRemote: true)])
    #expect(throws: VersionControlError.self) { try GitBackend.validateBranchName("-bad") }
    #expect(throws: VersionControlError.self) { try GitBackend.validateBranchName("a..b") }
}

@Test func loreJSONEventsParseStatusBranchesAndLocks() {
    let status = LoreBackend.parseStatus("""
        {"tagName":"repositoryStatusRevision","data":{"branchName":"main","revisionLocalNumber":7,"revisionRemoteNumber":5,"isLocalAhead":1,"isRemoteAhead":0,"remoteBranchExist":1}}
        {"tagName":"repositoryStatusFile","data":{"path":"Art/Hero.png","size":10,"action":"keep","type":"file","flagStaged":false,"flagDirty":true,"flagConflict":false,"flagConflictUnresolved":false,"fromPath":""}}
        {"tagName":"repositoryStatusFile","data":{"path":"Docs/Plan.md","size":3,"action":"add","type":"file","flagStaged":true,"flagConflict":false,"flagConflictUnresolved":false,"fromPath":""}}
        {"tagName":"repositoryStatusFile","data":{"path":"Docs/New.md","action":"move","type":"file","flagStaged":true,"fromPath":"Docs/Old.md"}}
        {"tagName":"repositoryStatusFile","data":{"path":"Docs","action":"keep","type":"directory","flagStaged":false}}
        {"tagName":"repositoryStatusFile","data":{"path":"Level.map","action":"keep","type":"file","flagConflict":true,"flagConflictUnresolved":true}}
        not json
        """)
    #expect(status.tracking == VersionControlTracking(branch: "main", upstream: "main", ahead: 2, behind: 0))
    #expect(status.changes == [
        VersionControlChange(path: "Art/Hero.png", state: .modified, isStaged: false),
        VersionControlChange(path: "Docs/Plan.md", state: .added, isStaged: true),
        VersionControlChange(path: "Docs/New.md", originalPath: "Docs/Old.md", state: .renamed, isStaged: true),
        VersionControlChange(path: "Level.map", state: .conflicted, isStaged: false),
    ])
    #expect(LoreBackend.parseHistory("12 Add hero art\n11 Init\n") == [
        VersionControlRevision(id: "12", summary: "Add hero art"), VersionControlRevision(id: "11", summary: "Init"),
    ])
    let branches = LoreBackend.parseBranches("""
        {"tagName":"branchListEntry","data":{"location":"local","name":"main","isCurrent":true}}
        {"tagName":"branchListEntry","data":{"location":"remote","name":"main","isCurrent":false}}
        {"tagName":"branchListEntry","data":{"location":"remote","name":"art","isCurrent":false}}
        """)
    #expect(branches == [VersionControlBranch(name: "main", isCurrent: true), VersionControlBranch(name: "art", isCurrent: false, isRemote: true)])
    #expect(LoreBackend.parseLocks(#"{"tagName":"lockFileStatus","data":{"path":"Art/Hero.png","owner":"ada","lockedAt":1}}"#) == ["Art/Hero.png"])
}

@Test func detectionPrefersTheNearestWorkingTreeAndLoreOverGit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcs-detect-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("Game/Project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    #expect(VersionControlDetector.repository(containing: project)?.system == .git)
    #expect(VersionControlDetector.repository(containing: project)?.root.lastPathComponent == root.lastPathComponent)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Game/.lore"), withIntermediateDirectories: true)
    #expect(VersionControlDetector.repository(containing: project)?.system == .lore)
}

@Test @MainActor func gitWorkingTreeRoundTripsThroughTheEditorModel() async throws {
    guard VersionControlTool.locate(.git) != nil else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcs-git-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = EditorVersionControl(projectRoot: root)
    await model.refresh()
    #expect(model.snapshot.availability == .noRepository)

    await model.initialize(.git)
    #expect(model.snapshot.repository?.system == .git)
    // Commits need an identity; keep it local to this repository.
    let tool = try #require(VersionControlTool.locate(.git))
    try await tool.run(["config", "user.name", "Guava Tests"], in: root)
    try await tool.run(["config", "user.email", "tests@guava.invalid"], in: root)

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

    await model.stage(model.snapshot.unstaged)
    #expect(model.snapshot.staged.map(\.state) == [.added, .added])
    #expect(await model.commit(message: "Add chapter one"))
    #expect(model.snapshot.status.changes.isEmpty)
    #expect(model.snapshot.history.first?.summary == "Add chapter one")
    #expect(model.snapshot.branches.contains { $0.isCurrent })

    try "# Chapter One\nRevised.\n".write(to: root.appendingPathComponent("Chapter.md"), atomically: true, encoding: .utf8)
    await model.refresh()
    #expect(model.snapshot.unstaged.map(\.state) == [.modified])
    await model.discard(model.snapshot.unstaged)
    #expect(try String(contentsOf: root.appendingPathComponent("Chapter.md"), encoding: .utf8) == "# Chapter One\n")

    await model.createBranch("draft")
    #expect(model.snapshot.status.tracking.branch == "draft")
    #expect(!(await model.commit(message: "   ")))
    #expect(model.snapshot.error != nil)
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
