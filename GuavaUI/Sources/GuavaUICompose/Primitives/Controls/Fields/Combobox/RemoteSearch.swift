import Foundation
import GuavaUIRuntime

/// Remote results for a `Combobox`: the component debounces typing, cancels
/// superseded requests, and shows loading, failure (with retry) and empty
/// states. The caller's data layer only maps a query to options.
///
/// ```swift
/// Combobox(selection: $userID, selectedLabel: user?.name,
///          search: ComboboxSearch { query in try await api.users(matching: query).map(\.option) })
/// ```
public struct ComboboxSearch<Value: Hashable>: @unchecked Sendable {
    /// Quiet time after the last keystroke before a request starts. Opening
    /// the list requests immediately.
    public var delay: Duration = .milliseconds(250)
    /// Shorter queries show a prompt instead of requesting.
    public var minimumQueryLength = 0
    let results: @Sendable (String) async throws -> [SelectOption<Value>]

    public init(results: @escaping @Sendable (String) async throws -> [SelectOption<Value>],
                configure: (inout Self) -> Void = { _ in }) {
        self.results = results
        configure(&self)
        minimumQueryLength = max(0, minimumQueryLength)
        if delay < .zero { delay = .zero }
    }
}

enum ComboboxSearchPhase: Equatable {
    case idle
    case tooShort(Int)
    case loading
    case loaded
    case failed(String)
}

/// Owns the in-flight request. Only the newest generation may publish, so a
/// slow response can never overwrite results for a later query.
final class ComboboxSearchSession<Value: Hashable>: @unchecked Sendable {
    private let registrar = ObservableStateRegistrar()
    private var storedPhase: ComboboxSearchPhase = .idle
    private var storedResults: [SelectOption<Value>] = []
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var query: String?

    var phase: ComboboxSearchPhase { registrar.access("phase"); return storedPhase }
    var results: [SelectOption<Value>] { registrar.access("phase"); return storedResults }

    /// Starts a request unless the same query is already loading or loaded.
    func request(_ query: String, search: ComboboxSearch<Value>, immediately: Bool = false, force: Bool = false,
                 enqueue: ((@escaping () -> Void) -> Void)? = UIWorkSchedulerHolder.enqueue) {
        if !force, query == self.query, storedPhase != .idle, !isFailure { return }
        cancel(); self.query = query
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= search.minimumQueryLength else {
            storedResults = []; publish(.tooShort(search.minimumQueryLength)); return
        }
        publish(.loading)
        let generation = generation, delay = immediately ? Duration.zero : search.delay
        guard let enqueue else { publish(.failed("Search needs a running host")); return }
        let schedule = UncheckedScheduler(run: enqueue)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<[SelectOption<Value>], any Error>
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                let options = try await search.results(trimmed)
                try Task.checkCancellation()
                outcome = .success(options)
            } catch is CancellationError { return }
            catch { outcome = .failure(error) }
            let box = UncheckedOutcome(outcome)
            schedule.run {
                guard let self, self.generation == generation else { return }
                self.task = nil
                switch box.value {
                case .success(let options):
                    var seen = Set<Value>()
                    self.storedResults = options.filter { seen.insert($0.value).inserted }
                    self.publish(.loaded)
                case .failure(let error):
                    self.publish(.failed(Self.message(for: error)))
                }
            }
        }
    }

    /// Cancels the pending request; loaded results stay for the next open.
    func cancel() {
        generation += 1; task?.cancel(); task = nil
        if storedPhase == .loading { query = nil; publish(.idle) }
    }

    private var isFailure: Bool { if case .failed = storedPhase { true } else { false } }
    private func publish(_ phase: ComboboxSearchPhase) {
        storedPhase = phase; registrar.invalidate("phase")
    }
    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Couldn’t load results"
    }
}

private struct UncheckedScheduler: @unchecked Sendable {
    let run: (@escaping () -> Void) -> Void
}

private struct UncheckedOutcome<Value: Hashable>: @unchecked Sendable {
    let value: Result<[SelectOption<Value>], any Error>
    init(_ value: Result<[SelectOption<Value>], any Error>) { self.value = value }
}

/// Cancels the pending request when the combobox leaves the tree. A modifier
/// rather than a wrapper view, so it adds no node and leaves sizing alone.
struct ComboboxSearchLifetime<Value: Hashable>: ViewModifier {
    let session: ComboboxSearchSession<Value>
    func apply(node: Node) {
        guard node.firstResource(Lifetime.self)?.session !== session else { return }
        node.addResource(Lifetime(session))
    }

    private final class Lifetime: NodeResource {
        let session: ComboboxSearchSession<Value>
        init(_ session: ComboboxSearchSession<Value>) { self.session = session }
        func mount(node: Node) {}
        func unmount(node: Node) { session.cancel() }
    }
}
