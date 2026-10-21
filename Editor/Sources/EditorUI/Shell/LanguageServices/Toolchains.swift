internal import EditorCore
internal import Foundation
internal import GuavaUI
internal import GuavaUIRuntime

final class LanguageToolchainSession: _ObservableObject, @unchecked Sendable {
    enum Confirmation { case install, remove }
    private let publisher = _ObservablePublisher<LanguageToolchainSession>()
    let app: EditorApplication
    private(set) var revision: UInt64 = 0
    var path: TextBuffer
    var version: String
    var confirmation: Confirmation?
    private(set) var installed: [SwiftToolchain] = []
    private(set) var message: String?
    private var operation: Task<Void, Never>?

    init(app: EditorApplication) {
        self.app = app
        let preferences = SwiftToolchainPreferences.load()
        path = TextBuffer(preferences.selectedPath ?? "")
        version = SwiftToolchainInstallation.releases.contains(where: { $0.version == preferences.releaseVersion })
            ? preferences.releaseVersion : SwiftToolchainInstallation.releases.first?.version ?? ""
        refresh()
    }

    func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
    func update(_ change: () -> Void) { change(); revision &+= 1; publisher.send() }

    func refresh() {
        Task { @MainActor [weak self] in
            let installed = await Task.detached { SwiftToolchainResolver.installed() }.value
            guard let self else { return }
            self.update { self.installed = installed }
        }
    }

    func select(_ path: String?) {
        run { [app] in try await app.selectSwiftToolchain(path: path) }
    }

    func confirm() {
        let action = confirmation
        update { confirmation = nil }
        let version = version
        if action == .install {
            run { [app] in
                var preferences = SwiftToolchainPreferences.load()
                preferences.releaseVersion = version
                try preferences.save()
                try await app.installSwiftToolchain(version: version, confirmed: true)
            }
        } else if action == .remove {
            run { [app] in
                let target = SwiftToolchainPreferences.directory.appendingPathComponent("Installed/swift-\(version).xctoolchain").resolvingSymlinksInPath()
                if let current = app.dynamicScriptManager.swiftToolchain?.rootURL.resolvingSymlinksInPath(),
                   current == target || current.path.hasPrefix(target.path + "/") {
                    throw SwiftToolchainError.invalidInstallation("Select another toolchain before removing the active toolchain.")
                }
                try await SwiftToolchainInstallation().remove(version: version)
            }
        }
    }

    func cancel() { operation?.cancel() }

    private func run(_ action: @escaping @MainActor @Sendable () async throws -> Void) {
        guard !app.workstation.scripts.snapshot.toolchainActivity.isBusy else { return }
        operation?.cancel()
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            self.update { self.message = nil }
            do {
                try await action()
                self.update { self.message = L("Swift toolchain updated"); self.path = TextBuffer(SwiftToolchainPreferences.load().selectedPath ?? "") }
            } catch is CancellationError {
                self.update { self.message = L("Installation cancelled") }
            } catch {
                self.update { self.message = error.localizedDescription }
            }
            self.refresh()
        }
    }
}

struct LanguageToolchainPanel: View {
    let session: LanguageToolchainSession
    let snapshot: ScriptWorkspaceSnapshot
    private var revision: Observed<LanguageToolchainSession, UInt64>

    init(session: LanguageToolchainSession, snapshot: ScriptWorkspaceSnapshot) {
        self.session = session; self.snapshot = snapshot
        revision = Observed(\.revision, on: session)
    }

    var body: some View {
        let _ = revision.wrappedValue
        let busy = snapshot.toolchainActivity.isBusy
        return Column(alignment: .leading, spacing: 8) {
            Text(L("Swift Toolchains")).font(.label).foregroundColor(.onSurface)
            if let current = snapshot.swiftToolchain {
                Text(current.compilerURL.path, lineLimit: 3).font(.mono).foregroundColor(.onSurfaceMuted)
                if let sdk = current.sdkURL { Text("SDK: " + sdk.path, lineLimit: 3).font(.caption).foregroundColor(.onSurfaceMuted) }
            }
            TextField(L("Toolchain directory or swiftc path"), text: Binding(get: { session.path }, set: { value in
                session.update { session.path = value }
            })).debugName("language-toolchain-path")
            Row(spacing: 6) {
                Button(L("Use Path"), isEnabled: !busy && !session.path.isEmpty) { session.select(session.path.stringValue) }.buttonStyle(.secondary)
                Button(L("Auto Detect"), isEnabled: !busy) { session.select(nil) }.buttonStyle(.secondary)
            }
            for toolchain in session.installed {
                AnyView(Button(toolchain.version, isEnabled: !busy, tooltip: toolchain.rootURL.path) { session.select(toolchain.rootURL.path) }
                    .buttonStyle(.ghost))
            }
            if !SwiftToolchainInstallation.releases.isEmpty {
                Row(spacing: 6) {
                    Select(selection: Binding(get: { session.version }, set: { value in session.update { session.version = value } }),
                           options: SwiftToolchainInstallation.releases.map { .init(value: $0.version, label: "Swift " + $0.version) }, width: 150)
                    Button(L("Download…"), isEnabled: !busy) { session.update { session.confirmation = .install } }.buttonStyle(.secondary)
                    Button(L("Remove…"), isEnabled: !busy) { session.update { session.confirmation = .remove } }.buttonStyle(.ghost)
                }
            } else {
                Text(L("Install Swift from swift.org, then select its toolchain path.")).font(.caption).foregroundColor(.onSurfaceMuted)
            }
            if let confirmation = session.confirmation {
                Text(confirmation == .install
                     ? L("Download the official signed Swift toolchain into this computer’s application support directory?")
                     : L("Remove this downloaded version? The active toolchain cannot be removed."), lineLimit: 3)
                    .font(.caption).foregroundColor(.warning)
                Row(spacing: 6) {
                    Button(L("Confirm"), isEnabled: !busy, action: session.confirm).buttonStyle(.primary).debugName("language-toolchain-confirm")
                    Button(L("Cancel")) { session.update { session.confirmation = nil } }.buttonStyle(.secondary)
                }
            }
            if busy {
                Row(spacing: 6) {
                    Spinner(size: 12)
                    Text(progressTitle).font(.caption).foregroundColor(.onSurfaceVariant)
                    Button(L("Cancel"), action: session.cancel).buttonStyle(.ghost)
                }
                if case let .installation(.downloading(received, total)) = snapshot.toolchainActivity, let total, total > 0 {
                    ProgressView(value: Double(received) / Double(total)) { $0.height = 4 }
                }
            }
            if let message = session.message { Text(message, lineLimit: 4).font(.caption).foregroundColor(.onSurfaceVariant) }
            if case let .failed(message) = snapshot.toolchainActivity { Text(message, lineLimit: 4).font(.caption).foregroundColor(.error) }
        }.padding(12).debugName("language-toolchain-panel")
    }

    private var progressTitle: String {
        switch snapshot.toolchainActivity {
        case .selecting: L("Checking Swift Toolchain…")
        case let .installation(.downloading(received, total)):
            L("Downloading Swift…") + " \(received / 1_048_576) MB" + (total.map { " / \($0 / 1_048_576) MB" } ?? "")
        case .installation(.verifying): L("Verifying Swift…")
        case .installation(.installing): L("Installing Swift…")
        default: L("Checking Swift Toolchain…")
        }
    }
}
