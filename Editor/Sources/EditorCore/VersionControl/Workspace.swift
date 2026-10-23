import Foundation
import GuavaUICompose

/// The project's working tree as the editor sees it. Detection, status reads
/// and every operation run off the main thread; results are published as one
/// snapshot. Commands are serialized, so a refresh never interleaves with a commit.
public final class EditorVersionControl: _ObservableObject, @unchecked Sendable {
    private let publisher = _ObservablePublisher<EditorVersionControl>()
    private let projectRoot: URL
    private let plugins: StepPlugins
    private var backend: (any VersionControlBackend)?
    private var queue: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    public private(set) var snapshot = VersionControlSnapshot()
    /// Called after an operation changed files on disk, so open documents reload.
    var didChangeFiles: (() -> Void)?

    /// `plugins` runs the bundled Git and Lore plugins that drive every command.
    init(projectRoot: URL, plugins: StepPlugins) {
        self.projectRoot = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        self.plugins = plugins
    }

    // MARK: Lifecycle

    /// Polls the working tree while the editor runs; Lore's scan walks the
    /// disk, so it polls less often.
    public func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.snapshot.operation == nil { await self.refresh() }
                let seconds: UInt64 = self.snapshot.repository?.system == .lore ? 15 : 4
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    public func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
    }

    /// Re-detects the repository, then reads status, history, branches and locks.
    @MainActor
    public func refresh() async {
        await serialize(nil) {}
    }

    // MARK: Operations

    @MainActor public func stage(_ changes: [VersionControlChange]) async {
        await perform(.staging) { try await $0.stage(changes.flatMap { [$0.originalPath, $0.path].compactMap { $0 } }) }
    }

    @MainActor public func unstage(_ changes: [VersionControlChange]) async {
        await perform(.unstaging) { try await $0.unstage(changes.map(\.path)) }
    }

    @MainActor public func discard(_ changes: [VersionControlChange]) async {
        await perform(.discarding, changesFiles: true) { try await $0.discard(changes) }
    }

    /// Commits staged changes, or every change when nothing is staged.
    @MainActor @discardableResult
    public func commit(message: String) async -> Bool {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            publish { $0.error = "Enter a commit message." }
            return false
        }
        let stageAll = snapshot.staged.isEmpty
        return await perform(.committing) { try await $0.commit(message: message, stageAll: stageAll) }
    }

    @MainActor public func pull() async { await perform(.pulling, changesFiles: true) { try await $0.pull() } }
    @MainActor public func push() async { await perform(.pushing) { try await $0.push() } }

    @MainActor public func switchBranch(_ name: String) async {
        await perform(.switchingBranch, changesFiles: true) { try await $0.switchBranch(name) }
    }

    @MainActor public func createBranch(_ name: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        await perform(.creatingBranch) { try await $0.createBranch(name) }
    }

    @MainActor public func setLocked(_ locked: Bool, paths: [String]) async {
        await perform(.locking) { try await $0.setLocked(locked, paths: paths) }
    }

    /// Shows `change` in the editor's diff tab and reads its diff.
    @MainActor
    public func compare(_ change: VersionControlChange) async {
        publish { $0.comparison = VersionControlComparison(change: change) }
        await loadComparison()
    }

    public func endComparison() {
        publish { $0.comparison = nil }
    }

    @MainActor
    private func loadComparison() async {
        guard let comparison = snapshot.comparison, comparison.isCurrent, let backend else { return }
        let text: String
        do { text = try await backend.diff(comparison.change) } catch { text = error.localizedDescription }
        guard snapshot.comparison?.change == comparison.change else { return }
        publish { $0.comparison?.diff = text }
    }

    /// The unified diff of one change; failures read as an explanation.
    @MainActor
    public func diff(_ change: VersionControlChange) async -> String {
        guard let backend else { return "" }
        do { return try await backend.diff(change) } catch { return error.localizedDescription }
    }

    /// Creates a repository for the project directory. Lore needs its server URL.
    @MainActor
    public func initialize(_ system: VersionControlSystem, loreRemote: String? = nil) async {
        let root = projectRoot
        await serialize(.initializing) { [weak self] in
            guard let self else { return }
            let plugin = try self.plugins.plugin(for: system, workspace: root)
            _ = try await plugin.perform(["op": "init", "remote": loreRemote ?? ""])
            try Self.ignoreMachineState(in: root, file: VersionControlProvider.provider(for: system)?.contribution.ignoreFile ?? ".gitignore")
            self.backend = nil
        }
    }

    /// The editor's per-machine state under `.guava` (observation logs, plugin
    /// approvals and preferences) is not project content. Existing rules are kept.
    static let machineStatePatterns = [
        ".guava/observation/", ".guava/plugin_authorizations.json", ".guava/disabled_bundled_plugins.json", ".guava/sourcekit-lsp/",
    ]

    static func ignoreMachineState(in root: URL, file name: String) throws {
        let url = root.appendingPathComponent(name)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = Set(existing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = machineStatePatterns.filter { !lines.contains($0) }
        guard !missing.isEmpty else { return }
        var text = existing
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += "# Guava Studio machine-local state\n" + missing.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: Paths

    /// The project-relative path of a repository path, when it lies in the project.
    public func projectPath(forRepositoryPath path: String) -> String? {
        guard let root = snapshot.repository?.root else { return nil }
        let absolute = root.appendingPathComponent(path).standardizedFileURL.path
        let base = projectRoot.path.hasSuffix("/") ? projectRoot.path : projectRoot.path + "/"
        return absolute.hasPrefix(base) ? String(absolute.dropFirst(base.count)) : nil
    }

    /// Project-relative paths with their working-tree state, for file trees.
    /// Unstaged state wins over staged so pending edits stay visible.
    public var projectFileStates: [String: VersionControlFileState] {
        var result: [String: VersionControlFileState] = [:]
        for change in snapshot.status.changes.sorted(by: { $0.isStaged && !$1.isStaged }) {
            if let path = projectPath(forRepositoryPath: change.path) { result[path] = change.state }
        }
        return result
    }

    // MARK: Execution

    @MainActor @discardableResult
    private func perform(_ operation: VersionControlOperation, changesFiles: Bool = false,
                         _ body: @escaping @Sendable (any VersionControlBackend) async throws -> Void) async -> Bool {
        await serialize(operation) { [weak self] in
            guard let self else { return }
            guard let backend = self.backend else {
                throw VersionControlError.unsupported("This project is not in a Git or Lore working tree.")
            }
            try await body(backend)
            if changesFiles { self.didChangeFiles?() }
        }
    }

    /// Runs one command at a time, then re-reads the repository whatever the outcome.
    @MainActor @discardableResult
    private func serialize(_ operation: VersionControlOperation?,
                           _ body: @escaping @MainActor () async throws -> Void) async -> Bool {
        let previous = queue
        let task = Task { @MainActor [weak self] () -> Bool in
            await previous?.value
            guard let self else { return false }
            if let operation { self.publish { $0.operation = operation } }
            var succeeded = false
            do {
                try await body()
                succeeded = true
                if operation != nil { self.publish { $0.error = nil } }
            } catch {
                self.publish { $0.error = error.localizedDescription }
            }
            await self.reload()
            self.publish { $0.operation = nil }
            return succeeded
        }
        queue = Task { _ = await task.value }
        return await task.value
    }

    @MainActor
    private func reload() async {
        let installed = plugins.installedSystems
        let root = projectRoot
        let disabled = Set(((try? BundledPlugins.disabled(in: root.path)) ?? []).compactMap { id in
            VersionControlProvider.bundled.first { $0.pluginID == id }?.system
        })
        publish { $0.disabledSystems = disabled }
        let providers = plugins.runtime.versionControlProviders
        let repository = await Task.detached { VersionControlProvider.repository(containing: root, excluding: disabled, among: providers) }.value
        guard let repository else {
            backend = nil
            publish { $0 = VersionControlSnapshot(availability: .noRepository, installedSystems: installed, disabledSystems: disabled, error: $0.error) }
            return
        }
        if backend?.repository != repository {
            do {
                backend = try plugins.backend(for: repository)
            } catch VersionControlError.toolMissing {
                backend = nil
            } catch {
                backend = nil
                publish {
                    $0 = VersionControlSnapshot(availability: .ready(repository), installedSystems: installed,
                                                disabledSystems: disabled, error: error.localizedDescription)
                }
                return
            }
        }
        guard let backend else {
            publish {
                $0 = VersionControlSnapshot(availability: .toolMissing(repository.system), installedSystems: installed,
                                            disabledSystems: disabled, error: $0.error)
            }
            return
        }
        do {
            async let status = backend.status()
            async let history = backend.history(limit: 50)
            async let branches = backend.branches()
            async let locks = backend.locks()
            let result = try await (status, history, branches, locks)
            publish {
                $0.availability = .ready(repository)
                $0.installedSystems = installed
                $0.status = result.0
                $0.history = result.1
                $0.branches = result.2
                $0.locks = result.3
                $0.comparison = $0.comparison.map { Self.follow($0, in: result.0.changes) }
            }
            await loadComparison()
        } catch {
            publish {
                $0.availability = .ready(repository)
                $0.error = error.localizedDescription
            }
        }
    }

    /// The compared file in the latest status: its own area first, then the other,
    /// so staging or unstaging it keeps the tab on the same file.
    static func follow(_ comparison: VersionControlComparison, in changes: [VersionControlChange]) -> VersionControlComparison {
        let path = comparison.change.path
        guard let change = changes.first(where: { $0.path == path && $0.isStaged == comparison.change.isStaged })
                ?? changes.first(where: { $0.path == path }) else {
            var gone = comparison
            gone.isCurrent = false
            return gone
        }
        return VersionControlComparison(change: change, diff: change == comparison.change ? comparison.diff : nil)
    }

    private func publish(_ change: (inout VersionControlSnapshot) -> Void) {
        var next = snapshot
        change(&next)
        guard next != snapshot else { return }
        snapshot = next
        publisher.send()
    }

    public func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    public func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}

private extension VersionControlSnapshot {
    init(availability: Availability, installedSystems: Set<VersionControlSystem>,
         disabledSystems: Set<VersionControlSystem>, error: String?) {
        self.init()
        self.availability = availability
        self.installedSystems = installedSystems
        self.disabledSystems = disabledSystems
        self.error = error
    }
}
