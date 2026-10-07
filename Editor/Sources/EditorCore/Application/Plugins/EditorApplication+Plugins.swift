import AIRuntime
import ContextMemory
import AssetPipeline
import AudioRuntime
import CapabilityRuntime
import EngineCore
import EngineKernel
import IntentRuntime
import ObservationBus
import PerceptionRuntime
import PluginRuntime
import SemanticPipeline
import RenderBackend
import RHIWGPU
import SceneRuntime
import GuavaUICompose
import GuavaUIRuntime
import Foundation
import SIMDCompat

extension EditorApplication {
    struct PendingPluginApproval {
        var packageURL: URL
        var inspection: PluginInspection
    }

    // MARK: - Isolated AI plugins

    /// Inspects WIT, manifest metadata, and Component exports without enabling
    /// or exposing the plugin. The returned value is what the UI must show
    /// before constructing an explicit authorization record.
    @MainActor
    public func inspectPlugin(at pluginURL: URL) throws -> PluginInspection {
        try resolvedPluginHostClient().inspectPlugin(at: pluginURL)
    }

    /// Call only after the user has approved the inspection shown by the UI.
    /// Any code, WIT, permission, or schema change makes this record invalid.
    public func makePluginAuthorization(
        afterUserApprovalOf inspection: PluginInspection,
        at date: Date = Date()
    ) throws -> PluginAuthorizationRecord {
        try PluginAuthorizationRecord(inspection: inspection, authorisedAt: date)
    }

    /// A stored record is reusable only when every current inspection field is
    /// identical. Merely finding a record never loads or exposes the plugin.
    public func storedPluginAuthorization(
        for inspection: PluginInspection
    ) -> PluginAuthorizationRecord? {
        pluginAuthorizationStore.authorization(for: inspection)
    }

    /// Loads an already-authorized package into the isolated host, rebuilds the
    /// one Registry used by Editor AI and MCP, and invalidates every old Draft.
    @MainActor
    @discardableResult
    public func enablePlugin(
        at pluginURL: URL,
        authorization: PluginAuthorizationRecord
    ) async throws -> PluginInspection {
        guard pluginBindings[authorization.pluginID] == nil else {
            throw EditorPluginCapabilityError.pluginAlreadyEnabled(authorization.pluginID)
        }
        let client = try resolvedPluginHostClient()
        let binding = try await Task.detached(priority: .userInitiated) {
            try client.loadPlugin(at: pluginURL, authorization: authorization)
        }.value
        var nextBindings = pluginBindings
        nextBindings[binding.pluginID] = binding
        let executor: PluginCapabilityExecutor
        do {
            executor = try PluginCapabilityExecutor(
                bindings: nextBindings.values.sorted { $0.pluginID < $1.pluginID },
                invoker: client
            )
            try pluginAuthorizationStore.record(authorization)
        } catch {
            _ = try? await Task.detached(priority: .userInitiated) {
                try client.unloadPlugin(at: pluginURL)
            }.value
            throw error
        }
        pluginBindings = nextBindings
        await activatePluginExecutor(executor)
        return binding.inspection
    }

    @MainActor
    public func disablePlugin(id pluginID: String) async throws {
        guard let binding = pluginBindings[pluginID] else {
            throw EditorPluginCapabilityError.pluginNotEnabled(pluginID)
        }
        var unloadError: Error?
        do {
            let client = pluginHostClient
            let pluginURL = URL(fileURLWithPath: binding.pluginPath,
                                isDirectory: true)
            try await Task.detached(priority: .userInitiated) {
                try client?.unloadPlugin(at: pluginURL)
            }.value
        } catch {
            unloadError = error
        }
        pluginBindings.removeValue(forKey: pluginID)
        let executor: PluginCapabilityExecutor?
        do {
            if pluginBindings.isEmpty {
                executor = nil
            } else if let client = pluginHostClient {
                executor = try PluginCapabilityExecutor(
                    bindings: pluginBindings.values.sorted { $0.pluginID < $1.pluginID },
                    invoker: client
                )
            } else {
                executor = nil
            }
        } catch {
            // Rebuilding the remaining registry is part of the trust boundary. If it
            // cannot be proven consistent, discard every in-memory plugin binding.
            pluginBindings.removeAll()
            await activatePluginExecutor(nil)
            throw error
        }
        await activatePluginExecutor(executor)
        if let unloadError { throw unloadError }
    }

    @MainActor
    public func revokePluginAuthorization(id pluginID: String) async throws {
        var disableError: Error?
        if pluginBindings[pluginID] != nil {
            do {
                try await disablePlugin(id: pluginID)
            } catch {
                disableError = error
            }
        }
        try pluginAuthorizationStore.remove(pluginID: pluginID)
        if let disableError { throw disableError }
    }

    public func enabledPluginInspections() -> [PluginInspection] {
        pluginBindings.values.map(\.inspection).sorted {
            $0.manifest.id < $1.manifest.id
        }
    }

    public var isPluginHostAvailable: Bool {
        trustedPluginHostExecutableURL != nil
    }

    /// Starts the explicit Settings-panel flow. Inspection does not load the
    /// component and the package URL is retained only in private process
    /// memory, never in observable/project state.
    @MainActor
    public func inspectPluginForManagement(at pluginURL: URL) async {
        pendingPluginApproval = nil
        publishPluginManagement(phase: .inspecting,
                                candidate: nil,
                                message: nil)
        do {
            let client = try resolvedPluginHostClient()
            let inspection = try await Task.detached(priority: .userInitiated) {
                try client.inspectPlugin(at: pluginURL)
            }.value
            let reusable = storedPluginAuthorization(for: inspection) != nil
            pendingPluginApproval = PendingPluginApproval(
                packageURL: pluginURL.standardizedFileURL,
                inspection: inspection
            )
            publishPluginManagement(
                phase: .awaitingAuthorization,
                candidate: EditorPluginInspectionSummary(
                    inspection: inspection,
                    hasReusableAuthorization: reusable
                ),
                message: reusable
                    ? "This exact plugin build was previously authorized. Review it before enabling."
                    : "Review the code hashes, imports, access level, and capabilities before authorizing."
            )
        } catch {
            publishPluginManagement(phase: .failed,
                                    candidate: nil,
                                    message: Self.pluginManagementErrorMessage(error))
        }
    }

    /// Called only by an explicit user action after the inspection summary is
    /// visible. The host re-inspects the package during load, so a file change
    /// between review and approval fails closed.
    @MainActor
    public func authorizeAndEnableInspectedPlugin() async {
        guard let pending = pendingPluginApproval else {
            publishPluginManagement(
                phase: .failed,
                candidate: nil,
                message: EditorPluginCapabilityError.noPendingPluginApproval.localizedDescription
            )
            return
        }
        let candidate = EditorPluginInspectionSummary(
            inspection: pending.inspection,
            hasReusableAuthorization: storedPluginAuthorization(for: pending.inspection) != nil
        )
        publishPluginManagement(phase: .enabling,
                                candidate: candidate,
                                message: nil)
        do {
            let authorization = try storedPluginAuthorization(for: pending.inspection)
                ?? makePluginAuthorization(afterUserApprovalOf: pending.inspection)
            let enabledInspection = try await enablePlugin(
                at: pending.packageURL,
                authorization: authorization
            )
            pendingPluginApproval = nil
            publishPluginManagement(
                phase: .idle,
                candidate: nil,
                message: "Enabled plugin '\(enabledInspection.manifest.name)'."
            )
        } catch {
            publishPluginManagement(phase: .failed,
                                    candidate: candidate,
                                    message: Self.pluginManagementErrorMessage(error))
        }
    }

    @MainActor
    public func cancelPluginApproval() {
        pendingPluginApproval = nil
        publishPluginManagement(phase: .idle,
                                candidate: nil,
                                message: nil)
    }

    @MainActor
    public func disablePluginFromManagement(id pluginID: String) async {
        do {
            try await disablePlugin(id: pluginID)
            publishPluginManagement(phase: .idle,
                                    candidate: store.state.assistant.pluginManagement.candidate,
                                    message: "Disabled plugin '\(pluginID)'.")
        } catch {
            publishPluginManagement(phase: .failed,
                                    candidate: store.state.assistant.pluginManagement.candidate,
                                    message: Self.pluginManagementErrorMessage(error))
        }
    }

    @MainActor
    public func revokePluginFromManagement(id pluginID: String) async {
        do {
            try await revokePluginAuthorization(id: pluginID)
            if pendingPluginApproval?.inspection.manifest.id == pluginID {
                pendingPluginApproval = nil
            }
            publishPluginManagement(phase: .idle,
                                    candidate: nil,
                                    message: "Revoked authorization for plugin '\(pluginID)'.")
        } catch {
            publishPluginManagement(phase: .failed,
                                    candidate: store.state.assistant.pluginManagement.candidate,
                                    message: Self.pluginManagementErrorMessage(error))
        }
    }

    @MainActor
    private func publishPluginManagement(
        phase: EditorPluginManagementPhase,
        candidate: EditorPluginInspectionSummary?,
        message: String?
    ) {
        let enabled = pluginBindings.values.map {
            EditorPluginInspectionSummary(inspection: $0.inspection,
                                          hasReusableAuthorization: true)
        }
        store.dispatch(.setPluginManagementState(
            EditorPluginManagementState(phase: phase,
                                        candidate: candidate,
                                        enabled: enabled,
                                        message: message)
        ))
        displayInvalidationHandler?()
    }

    private static func pluginManagementErrorMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    @MainActor
    private func resolvedPluginHostClient() throws -> PluginHostProcessClient {
        if let existing = pluginHostClient { return existing }
        guard let resolvedURL = trustedPluginHostExecutableURL else {
            throw EditorPluginCapabilityError.pluginHostUnavailable
        }
        let client = PluginHostProcessClient(executableURL: resolvedURL)
        client.onInvalidation = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.invalidatePluginsAfterHostRestart()
                }
            }
        }
        pluginHostClient = client
        return client
    }

    @MainActor
    private func invalidatePluginsAfterHostRestart() async {
        pluginBindings.removeAll()
        pendingPluginApproval = nil
        await activatePluginExecutor(nil)
        store.dispatch(.setPluginManagementState(
            EditorPluginManagementState(
                phase: .failed,
                message: "PluginHost restarted. Enabled plugins and pending approvals were invalidated."
            )
        ))
        store.dispatch(.setAIStatusMessage(
            "PluginHost restarted. Plugin capabilities and pending plans were invalidated."
        ))
    }

    @MainActor
    private func activatePluginExecutor(_ executor: PluginCapabilityExecutor?) async {
        await pendingAISetupTask?.value
        pendingAISetupTask = nil
        pluginCapabilityExecutor = executor
        let settings = store.state.assistant.capabilitySettings
        intentCoordinator.configureCapabilityPlanner(
            Self.makeCapabilityInvocationPlanner(for: settings,
                                                 pluginCapabilityExecutor: executor)
        )
        await mcpCapabilitySessions.replaceRegistry(
            executor?.registry ?? .aiDefault,
            exposurePolicy: executor?.exposurePolicy
                ?? CapabilityExposurePolicy(activeReleasePhase: .stable,
                                            allowedDomains: ["scene"],
                                            maximumCapabilities: 16),
            pluginAuthorities: executor?.pluginAuthorities ?? [:]
        )

        let oldSession = session
        cancelActiveAIRequest()
        await oldSession?.cancelActiveRun()
        let world = await aiWorldContext.snapshot()
        let nextSession = Self.makeSession(
            for: store.state.assistant.aiSettings,
            initialWorldView: world,
            pluginCapabilityExecutor: executor,
            pluginQuerySnapshotProvider: makePluginQuerySnapshotProvider()
        )
        session = nextSession
        if let nextSession {
            await nextSession.setProjectToolExecutor(makeProjectToolExecutor())
            await nextSession.setObservationBus(observationBus)
            await nextSession.setContextMemory(contextMemoryStore)
            await nextSession.setWorkflowContext(Self.workflowContext(
                for: store.state.workspace.mode,
                scriptEntries: scene.scriptCatalogEntries
            ))
        }
        agentExecution.proposal = nil
        agentExecution.assistantMessageID = nil
        store.dispatch(.clearChatHistory)
    }

    func makePluginQuerySnapshotProvider() -> PluginQuerySnapshotProvider? {
        guard pluginCapabilityExecutor != nil else { return nil }
        return { [weak self] pluginID, revision in
            guard let self else {
                throw EditorPluginCapabilityError.pluginNotEnabled(pluginID)
            }
            return try await MainActor.run {
                try self.makePluginQuerySnapshot(pluginID: pluginID,
                                                 sceneRevision: revision)
            }
        }
    }

    func makePluginQuerySnapshot(
        pluginID: String,
        sceneRevision: UInt64
    ) throws -> PluginQuerySnapshot? {
        guard let executor = pluginCapabilityExecutor else {
            throw EditorPluginCapabilityError.pluginNotEnabled(pluginID)
        }
        let imports = try executor.requiredImports(forPluginID: pluginID)
        guard !imports.isEmpty else { return nil }
        guard scene.revision == sceneRevision else {
            throw EditorPluginCapabilityError.sceneRevisionChanged(
                expected: sceneRevision,
                actual: scene.revision
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var scenePayload: Data?
        var selectionPayload: Data?
        var assetPayload: Data?

        if imports.contains(.sceneQuery) {
            let snapshot = SceneSemanticEncoder().encode(
                scene.scene,
                selectedEntityID: store.state.selection.selectedEntityID,
                workspaceMode: store.state.workspace.mode.rawValue,
                localeIdentifier: nil
            )
            scenePayload = try encoder.encode(snapshot)
        }
        if imports.contains(.selectionQuery) {
            let selected = store.state.selection.selectedEntityID.map { ["scene:\($0)"] } ?? []
            selectionPayload = try JSONSerialization.data(
                withJSONObject: ["selected": selected],
                options: [.sortedKeys]
            )
        }
        if imports.contains(.assetMetadataQuery) {
            let assets: [[String: Any]] = EditorAssetCatalog.entries().map { asset in
                [
                    "id": asset.id,
                    "name": asset.name,
                    "relative_path": asset.relativePath,
                    "kind": String(describing: asset.kind),
                    "mesh_index": asset.meshIndex,
                ]
            }
            assetPayload = try JSONSerialization.data(
                withJSONObject: ["assets": assets],
                options: [.sortedKeys]
            )
        }
        let snapshot = PluginQuerySnapshot(sceneRevision: sceneRevision,
                                           scene: scenePayload,
                                           selection: selectionPayload,
                                           assetMetadata: assetPayload)
        try snapshot.validate(for: imports)
        return snapshot
    }

    func makePluginQuerySnapshots(
        for drafts: [CapabilityInvocationDraft],
        sceneRevision: UInt64
    ) throws -> [String: PluginQuerySnapshot] {
        var result: [String: PluginQuerySnapshot] = [:]
        for pluginID in Set(drafts.compactMap(\.sourcePluginID)).sorted() {
            if let snapshot = try makePluginQuerySnapshot(pluginID: pluginID,
                                                          sceneRevision: sceneRevision) {
                result[pluginID] = snapshot
            }
        }
        return result
    }
}
