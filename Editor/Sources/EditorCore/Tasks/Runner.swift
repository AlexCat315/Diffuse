import Foundation
import CoveUICompose

/// The project's build, test and run tasks. The plugin that contributes tasks
/// for this kind of project decides each command and reads its output; this
/// runs one task at a time through the plugin's process permission, shows
/// output as it arrives and publishes what the plugin read.
public final class EditorTasks: _ObservableObject, @unchecked Sendable {
    private let publisher = _ObservablePublisher<EditorTasks>()
    private let root: URL
    private let plugins: StepPlugins
    private var runner: Task<Void, Never>?
    public private(set) var snapshot = TaskSnapshot()
    /// Each task's start, its raw output (terminal colours included) and its end,
    /// for the view that shows it. Called on the main thread.
    public var onOutput: ((TaskOutputEvent) -> Void)?

    init(root: URL, plugins: StepPlugins) {
        self.root = root.standardizedFileURL
        self.plugins = plugins
        snapshot.title = TaskProvider.provider(for: self.root, among: plugins.runtime.taskProviders)?.contribution.title
    }

    // MARK: Project

    /// Finds the provider again and re-reads the project's description.
    @MainActor
    public func refresh() async {
        let provider = TaskProvider.provider(for: root, among: plugins.runtime.taskProviders)
        publish { $0.title = provider?.contribution.title; if provider == nil { $0.description = nil } }
        guard let provider, let plugin = try? plugins.plugin(for: provider.step, workspace: root),
              case let .result(data)? = try? await plugin.perform(["op": "describe"]),
              let description = try? JSONDecoder().decode(TaskProjectDescription.self, from: data) else { return }
        publish { $0.description = description }
    }

    // MARK: Tests

    /// Where the tests come from: the language service's index, so they are
    /// known without building. Set by the application.
    var testSource: (@Sendable () async throws -> [String])?
    private var languageObservation: AnyHashable?
    private var languageKey: LanguageKey?
    private var testRefresh: Task<Void, Never>?

    private struct LanguageKey: Equatable {
        let isReady: Bool
        let isIndexing: Bool
        let saved: [UInt64]
    }

    /// Lists the tests again whenever the language service settles: once it is
    /// ready, when indexing ends and after a file is saved.
    func follow(_ language: ScriptWorkspaceModel) {
        languageObservation = language._registerObserver { [weak self, weak language] in
            guard let self, let language else { return }
            MainActor.assumeIsolated { self.languageChanged(language.snapshot) }
        }
    }

    @MainActor
    private func languageChanged(_ language: ScriptWorkspaceSnapshot) {
        let key = LanguageKey(isReady: language.languageServiceState == .ready,
                              isIndexing: language.languageServiceDetails?.indexing != nil,
                              saved: language.documents.map(\.savedRevision))
        guard key != languageKey else { return }
        languageKey = key
        if key.isReady, !key.isIndexing { scheduleTestRefresh() }
    }

    @MainActor
    private func scheduleTestRefresh() {
        testRefresh?.cancel()
        testRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.refreshTests()
        }
    }

    /// Asks the test source again, keeping each known test's last result.
    @MainActor
    public func refreshTests() async {
        guard snapshot.isAvailable, let testSource, let identifiers = try? await testSource() else { return }
        publish { snapshot in
            let previous = Dictionary(snapshot.tests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            snapshot.tests = identifiers.map { previous[$0] ?? TaskTest(id: $0, status: .notRun, message: nil) }
        }
    }

    // MARK: Tasks

    // Entry points are called from UI actions on the main thread.
    public func build() { start(.build) }
    /// Runs every test, or the one named `id`.
    public func test(_ id: String? = nil) { start(.test, subject: id) }
    public func run(_ target: String) { start(.run, subject: target) }
    public func clean() { start(.clean) }
    public func resolve() { start(.resolve) }

    public func stop() {
        MainActor.assumeIsolated { runner?.cancel() }
    }

    private func start(_ kind: TaskKind, subject: String? = nil) {
        MainActor.assumeIsolated { begin(kind, subject: subject) }
    }

    @MainActor
    private func begin(_ kind: TaskKind, subject: String?) {
        guard snapshot.run?.isRunning != true else { return }
        guard let provider = TaskProvider.provider(for: root, among: plugins.runtime.taskProviders) else { return }
        publish { snapshot in
            snapshot.run = TaskRun(kind: kind, subject: subject)
            if kind != .run { snapshot.problems = [] }
            if kind == .test {
                for index in snapshot.tests.indices where subject == nil || snapshot.tests[index].id == subject {
                    snapshot.tests[index].status = .running
                    snapshot.tests[index].message = nil
                }
            }
        }
        if let run = snapshot.run { onOutput?(.started(run)) }
        let plugins = plugins, root = root, known = snapshot.tests.map(\.id)
        runner = Task { @MainActor [weak self] in
            var report: TaskReport?, failure: String?
            var operation: [String: Any] = ["op": kind.rawValue]
            switch kind {
            case .test:
                if let subject { operation["filter"] = subject }
                operation["known"] = known
            case .run: operation["target"] = subject ?? ""
            default: break
            }
            do {
                let plugin = try plugins.plugin(for: provider.step, workspace: root)
                let buffer = TaskOutputBuffer()
                let outcome = try await plugin.perform(operation) { chunk in
                    buffer.append(chunk)
                    Task { @MainActor in
                        let bytes = buffer.take()
                        if !bytes.isEmpty { self?.onOutput?(.output(bytes)) }
                    }
                }
                if case let .result(data) = outcome { report = try JSONDecoder().decode(TaskReport.self, from: data) }
            } catch is CancellationError {
                failure = "Stopped"
            } catch {
                failure = Task.isCancelled ? "Stopped" : error.localizedDescription
            }
            self?.finish(kind, report: report, failure: failure)
        }
    }

    @MainActor
    private func finish(_ kind: TaskKind, report: TaskReport?, failure: String?) {
        publish { snapshot in
            snapshot.run?.isRunning = false
            snapshot.run?.status = report?.exit
            snapshot.run?.failure = failure
            if let report {
                snapshot.problems = report.problems
                for result in report.tests ?? [] {
                    if let index = snapshot.tests.firstIndex(where: { $0.id == result.id }) { snapshot.tests[index] = result }
                    else { snapshot.tests.append(result) }
                }
            }
            // A test the output never reported on did not run to an answer.
            for index in snapshot.tests.indices where snapshot.tests[index].status == .running {
                snapshot.tests[index].status = .notRun
            }
        }
        if let run = snapshot.run { onOutput?(.finished(run)) }
        scheduleTestRefresh()
    }

    /// Where a problem's file is: absolute, or relative to the project folder.
    public func url(of problem: TaskProblem) -> URL {
        problem.file.hasPrefix("/") ? URL(fileURLWithPath: problem.file) : root.appendingPathComponent(problem.file)
    }

    private func publish(_ change: (inout TaskSnapshot) -> Void) {
        var next = snapshot
        change(&next)
        guard next != snapshot else { return }
        snapshot = next
        publisher.send()
    }

    public func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    public func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}

/// Output chunks arrive off the main actor; each main-actor hop takes
/// everything gathered so far, so bytes keep their order whichever hop runs first.
private final class TaskOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UInt8] = []

    func append(_ chunk: Data) { lock.withLock { pending.append(contentsOf: chunk) } }

    func take() -> [UInt8] {
        lock.withLock {
            defer { pending.removeAll(keepingCapacity: true) }
            return pending
        }
    }
}
