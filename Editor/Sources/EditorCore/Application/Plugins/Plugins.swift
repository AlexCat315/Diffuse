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
import NativeRHI
import SceneRuntime
import CoveUICompose
import CoveUIRuntime
import Foundation
import SIMDCompat

extension EditorApplication {
    // MARK: - Isolated AI plugins

    /// Inspects WIT, manifest metadata, and Component exports without enabling
    /// or exposing the plugin. The returned value is what the UI must show
    /// before constructing an explicit authorization record.
    @MainActor
    public func inspectPlugin(at pluginURL: URL) throws -> PluginInspection {
        let package = try PluginPackageLoader().load(at: pluginURL)
        if package.runtime == nil {
            try EditorThemeCatalog.validate(package)
            return PluginInspection(package: package, contracts: [])
        }
        // Inspection is a one-shot read of an uninstalled package: give it a
        // throwaway process so it never joins the pool serving enabled plugins.
        let client = PluginHostProcessClient(executableURL: try resolvedPluginHostExecutable())
        defer { client.stop() }
        return try client.inspectPlugin(at: pluginURL)
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
        pluginSession.authorizationStore.authorization(for: inspection)
    }

    /// Loads an already-authorized package into the isolated host, rebuilds the
    /// one Registry used by Editor AI and MCP, invalidating affected Drafts.
    @MainActor
    @discardableResult
    public func enablePlugin(
        at pluginURL: URL,
        authorization: PluginAuthorizationRecord
    ) async throws -> PluginInspection {
        configurePluginRuntime()
        let inspection: PluginInspection
        do { inspection = try await pluginSession.manager.enable(at: pluginURL, authorization: authorization) }
        catch { try? await synchronizePlugins(); throw error }
        do {
            try pluginSession.authorizationStore.record(authorization)
            if BundledPlugins.plugin(id: inspection.manifest.id) != nil {
                try BundledPlugins.setEnabled(true, id: inspection.manifest.id, in: projectDirectory, applicationWide: pluginSession.peers != nil)
            }
        } catch {
            try? await pluginSession.manager.disable(id: inspection.manifest.id)
            try? await synchronizePlugins()
            throw error
        }
        try await synchronizePlugins()
        return inspection
    }

    @MainActor
    func configurePluginRuntime() {
        pluginSession.hosts.hostCallHandler = { [weak self] owner, call in
            let waiter = PluginHostCallWaiter()
            guard let queue = self?.pluginSession.workbench.uiQueue else { throw PluginCommandError.unavailable }
            queue.schedule { [weak self] in
                    do {
                        guard let self else { throw PluginCommandError.unavailable }
                        waiter.complete(.success(try self.handlePluginHostCall(owner: owner, call: call)))
                    } catch { waiter.complete(.failure(error)) }
            }
            return try waiter.wait()
        }
        pluginSession.manager.configureRuntime(PluginRuntimeDriver(activate: { [weak self] url, authorization in
            guard let self else { throw PluginManagerError.stopped }
            let (hosts, context) = try await MainActor.run {
                (self.pluginSession.hosts, try self.pluginProcessContext(for: authorization))
            }
            let pluginID = authorization.pluginID
            let binding = try await Task.detached(priority: .userInitiated) {
                try hosts.client(forPluginID: pluginID)
                    .loadPlugin(at: url, authorization: authorization, processContext: context)
            }.value
            let client = try hosts.client(forPluginID: pluginID)
            let declarations = (try? await Self.componentDeclarations(for: binding, client: client)) ?? []
            let components = self.pluginSession.components
            components.set(declarations, pluginID: binding.pluginID)
            return PluginRuntimeActivation(binding: binding, registration: Registration { [weak components] in
                components?.remove(pluginID: binding.pluginID)
            })
        }, deactivate: { [weak self] binding in
            await MainActor.run { self?.pluginSession.serviceJobs.cancel(owner: binding.pluginID) }
            guard let hosts = await MainActor.run(body: { self?.pluginSession.hosts }) else { return }
            try await Task.detached {
                // Unloading drops this plugin's process only; its neighbours
                // keep their own.
                if let client = hosts.existing(binding.pluginID) {
                    try client.unloadPlugin(at: URL(fileURLWithPath: binding.pluginPath))
                }
                _ = hosts.discard(binding.pluginID)
            }.value
        }, stop: { [weak self] in self?.pluginSession.hosts.stopAll() }))
    }

    @MainActor
    public func activatePlugins(event: String) async throws {
        configurePluginRuntime()
        do { try await pluginSession.manager.activate(event: event) }
        catch { try? await synchronizePlugins(); throw error }
        try await synchronizePlugins()
    }

    /// Calls the reserved `components` capability, if the plugin declares it.
    static func componentDeclarations(
        for binding: PluginExecutionBinding,
        client: PluginHostProcessClient
    ) async throws -> [ComponentDescription] {
        let capabilityID = PluginComponentCapability.capabilityID(pluginID: binding.pluginID)
        guard PluginComponentCapability.declaresComponents(binding.inspection.contracts,
                                                           pluginID: binding.pluginID) else { return [] }
        let payload = try await Task.detached(priority: .userInitiated) {
            let result = try client.prepareCapability(binding: binding,
                                                      capabilityID: capabilityID,
                                                      input: PluginComponentCapability.input,
                                                      querySnapshot: nil)
            guard case let .read(data) = result else {
                throw EditorPluginCapabilityError.unexpectedComponentDeclarationResult(capabilityID)
            }
            return data
        }.value
        do { return try PluginComponentDeclaration.decode(payload) }
        catch { throw EditorPluginCapabilityError.invalidComponentDeclaration(binding.pluginID) }
    }

    @MainActor
    public func disablePlugin(id pluginID: String) async throws {
        let peers = pluginSession.peers?() ?? []
        for peer in peers where peer !== self && peer.enabledPluginManifests[pluginID] != nil {
            try await peer.disablePluginLocally(id: pluginID)
        }
        try await disablePluginLocally(id: pluginID)
    }

    @MainActor
    private func disablePluginLocally(id pluginID: String) async throws {
        let before = Set(pluginSession.manager.enabledManifests.keys)
        do { try await pluginSession.manager.disable(id: pluginID) }
        catch { try? await synchronizePlugins(); throw error }
        let removed = before.subtracting(pluginSession.manager.enabledManifests.keys)
        for id in removed where BundledPlugins.plugin(id: id) != nil {
            try BundledPlugins.setEnabled(false, id: id, in: projectDirectory, applicationWide: pluginSession.peers != nil)
        }
        try await synchronizePlugins()
    }

    @MainActor
    public func uninstallPlugin(id: String) async throws {
        do { try await pluginSession.manager.uninstall(id: id) }
        catch { try? await synchronizePlugins(); throw error }
        try pluginSession.authorizationStore.remove(pluginID: id)
        if BundledPlugins.plugin(id: id) != nil { try BundledPlugins.setEnabled(false, id: id, in: projectDirectory, applicationWide: pluginSession.peers != nil) }
        try await synchronizePlugins()
    }

    @MainActor
    public func uninstallPluginFromManagement(id: String) async {
        do {
            try await uninstallPlugin(id: id)
            if pluginSession.pendingApproval?.inspection.manifest.id == id { pluginSession.pendingApproval = nil }
            publishPluginManagement(phase: .idle, candidate: nil, message: nil)
        }
        catch { publishPluginManagement(phase: .failed, candidate: nil, message: Self.pluginManagementErrorMessage(error)) }
    }

    @MainActor
    func rebuildPluginExecutor() throws -> PluginCapabilityExecutor? {
        let bindings = pluginSession.manager.activeBindings.values.sorted { $0.pluginID < $1.pluginID }
        guard !bindings.isEmpty else { return nil }
        return try PluginCapabilityExecutor(bindings: bindings,
            enabledDeclarations: pluginSession.manager.enabledInspections,
            invoker: PluginHostRouter(pool: pluginSession.hosts))
    }

    @MainActor
    func synchronizePlugins() async throws {
        let previous = pluginSession.projection
        let task = Task { @MainActor [weak self] in
            _ = try? await previous?.value
            guard let self, !self.isShuttingDown else { return }
            try await self.projectPluginState()
        }
        pluginSession.projection = task
        try await task.value
    }

    @MainActor
    private func projectPluginState() async throws {
        pluginSession.components.apply(to: &scene.scene)
        do {
            // A concurrent reload may have withdrawn a provider while its
            // dependent is still bound; read only between manager operations.
            let executor = try await pluginSession.manager.readSettled { [self] in
                refreshContributionSnapshots()
                return try rebuildPluginExecutor()
            }
            await activatePluginExecutor(executor)
        }
        catch {
            await pluginSession.manager.invalidateRuntime()
            clearPluginComponents()
            await activatePluginExecutor(nil)
            throw error
        }
        publishPluginManagement(phase: .idle, candidate: store.state.assistant.pluginManagement.candidate, message: nil)
    }

    @MainActor
    public func revokePluginAuthorization(id pluginID: String) async throws {
        var disableError: Error?
        if enabledPluginManifests[pluginID] != nil {
            do {
                try await disablePlugin(id: pluginID)
            } catch {
                // Dependency/busy rejection leaves the mount live. Its stored
                // authority must remain paired with that binding as well.
                if enabledPluginManifests[pluginID] != nil { throw error }
                disableError = error
            }
        }
        try pluginSession.authorizationStore.remove(pluginID: pluginID)
        if let disableError { throw disableError }
    }

    public func enabledPluginInspections() -> [PluginInspection] {
        pluginSession.manager.enabledInspections
    }

    public var isPluginHostAvailable: Bool {
        trustedPluginHostExecutableURL != nil
    }

    /// Starts the explicit Settings-panel flow. Inspection does not load the
    /// component and the package URL is retained only in private process
    /// memory, never in observable/project state.
    @MainActor
    public func inspectPluginForManagement(at pluginURL: URL) async {
        // Bundled packages publish their own management state as they start;
        // a review opened meanwhile would be cleared.
        await pluginSession.bundledStartup?.value
        pluginSession.pendingApproval = nil
        publishPluginManagement(phase: .inspecting,
                                candidate: nil,
                                message: nil)
        do {
            let inspection = try inspectPlugin(at: pluginURL)
            if enabledPluginManifests[inspection.manifest.id] == nil {
                guard try await pluginSession.manager.install(at: pluginURL) == inspection else {
                    throw PluginAuthorizationError.noLongerValid
                }
            }
            let reusable = storedPluginAuthorization(for: inspection) != nil
            pluginSession.pendingApproval = PendingPluginApproval(
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
        guard let pending = pluginSession.pendingApproval else {
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
            // An approved update replaces the enabled build. Disable performs
            // the dependency check before withdrawing the old mount.
            if enabledPluginManifests[authorization.pluginID] != nil {
                try await disablePlugin(id: authorization.pluginID)
            }
            let enabledInspection = try await enablePlugin(
                at: pending.packageURL,
                authorization: authorization
            )
            pluginSession.pendingApproval = nil
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
        pluginSession.pendingApproval = nil
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
            if pluginSession.pendingApproval?.inspection.manifest.id == pluginID {
                pluginSession.pendingApproval = nil
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
    func publishPluginManagement(
        phase: EditorPluginManagementPhase,
        candidate: EditorPluginInspectionSummary?,
        message: String?
    ) {
        let installed = pluginSession.manager.statuses.map {
            EditorPluginInspectionSummary(inspection: $0.inspection,
                hasReusableAuthorization: storedPluginAuthorization(for: $0.inspection) != nil,
                lifecycle: .init(phase: $0.phase, isEnabled: $0.isEnabled, failure: $0.failure))
        }
        store.dispatch(.setPluginManagementState(
            EditorPluginManagementState(phase: phase,
                                        candidate: candidate,
                                        installed: installed,
                                        message: message)
        ))
        displayInvalidationHandler?()
    }

    @MainActor
    public func setInstalledPlugin(id: String, enabled: Bool) async {
        guard enabled else { await disablePluginFromManagement(id: id); return }
        guard let url = pluginSession.manager.packageURLs[id] else { return }
        do {
            let inspection = try inspectPlugin(at: url)
            guard let authorization = storedPluginAuthorization(for: inspection) else {
                await inspectPluginForManagement(at: url)
                return
            }
            try await enablePlugin(at: url, authorization: authorization)
        } catch {
            publishPluginManagement(phase: .failed, candidate: nil, message: Self.pluginManagementErrorMessage(error))
        }
    }

    static func pluginManagementErrorMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    @MainActor
    func resolvedPluginHostExecutable() throws -> URL {
        guard !isShuttingDown else { throw PluginManagerError.stopped }
        guard let resolvedURL = trustedPluginHostExecutableURL else {
            throw EditorPluginCapabilityError.pluginHostUnavailable
        }
        return resolvedURL
    }

    @MainActor
    func resolvedPluginHostClient(forPluginID pluginID: String) throws -> PluginHostProcessClient {
        try pluginSession.hosts.client(forPluginID: pluginID)
    }

    @MainActor
    private func invalidatePluginsAfterHostRestart(generation: UInt64) async {
        guard !isShuttingDown else { return }
        guard await pluginSession.manager.invalidateRuntime(before: generation) else { return }
        pluginSession.pendingApproval = nil
        try? await synchronizePlugins()
        publishPluginManagement(phase: .failed, candidate: nil,
            message: "PluginHost restarted. Active plugins require enabling again.")
    }


    func clearPluginComponents() {
        pluginSession.components.removeAll()
        pluginSession.components.apply(to: &scene.scene)
    }

    @MainActor
    func activatePluginExecutor(_ executor: PluginCapabilityExecutor?) async {
        let languageID = languageCatalog.languages.first { $0.server != nil }?.pluginID
        let languageBinding = languageID.flatMap { pluginSession.manager.activeBindings[$0] }
        let languageWasBound = dynamicScriptManager.languagePlugin.isBound
        if dynamicScriptManager.languagePlugin.bind(languageBinding,
            client: languageBinding.flatMap { pluginSession.hosts.existing($0.pluginID) }) {
            if languageWasBound { workstation.scripts.stopLanguageServiceForPluginChange() }
            if languageBinding != nil { workstation.scripts.startLanguageServiceForPluginChange() }
        }
        let aiIDs = Set(pluginSession.manager.activeBindings.values.filter { binding in
            let manifest = binding.inspection.manifest
            return binding.inspection.contracts.contains {
                manifest.exposesToAI(entryPoint: String($0.id.dropFirst(manifest.id.count + 1)))
            }
        }.map(\.pluginID))
        let authorities = (executor?.pluginAuthorities ?? [:]).filter { aiIDs.contains($0.key) }
        let provider = aiProviderCatalog.provider(id: store.state.assistant.aiSettings.providerID)
        let providerChanged = provider != pluginSession.aiProvider
        let aiChanged = authorities != pluginSession.aiAuthorities || providerChanged
        pluginSession.aiAuthorities = authorities
        pluginSession.aiProvider = provider
        pluginCapabilityExecutor = executor
        pluginSession.packageMonitor?.setPackages(pluginPackageURLs())
        guard aiChanged else { return }
        await pendingAISetupTask?.value
        pendingAISetupTask = nil
        pluginCapabilityExecutor = executor
        let settings = store.state.assistant.capabilitySettings
        intentCoordinator.configureCapabilityPlanner(
            Self.makeCapabilityInvocationPlanner(for: settings,
                                                 pluginCapabilityExecutor: executor)
        )
        await toolAccess.capabilitySessions.replaceRegistry(
            executor?.registry ?? .aiDefault,
            exposurePolicy: executor?.exposurePolicy
                ?? CapabilityExposurePolicy(activeReleasePhase: .stable,
                                            allowedDomains: ["scene"],
                                            maximumCapabilities: 16),
            pluginAuthorities: executor?.pluginAuthorities ?? [:]
        )

        if !providerChanged, let session {
            await session.replacePluginCapabilities(executor, querySnapshotProvider: makePluginQuerySnapshotProvider())
            agentExecution.proposal = nil
            return
        }
        let oldSession = session
        cancelActiveAIRequest()
        await oldSession?.cancelActiveRun()
        let world = await aiWorldContext.snapshot()
        let nextSession = Self.makeSession(
            for: store.state.assistant.aiSettings,
            providers: aiProviderCatalog,
            agent: agentCatalog.agent(id: store.state.assistant.aiSettings.agentID),
            initialWorldView: world,
            pluginCapabilityExecutor: executor,
            pluginQuerySnapshotProvider: makePluginQuerySnapshotProvider(),
            toolPolicy: toolAccess.policy
        )
        session = nextSession
        if let nextSession {
            await nextSession.setProjectToolExecutor(makeProjectToolExecutor())
            await nextSession.setComponentDescriptionProvider(makeComponentDescriptionProvider())
            await nextSession.setObservationBus(observationBus)
            await nextSession.setContextMemory(contextMemoryStore)
            await nextSession.setWorkflowContext(Self.workflowContext(
                for: store.state.content,
                scriptEntries: scene.scriptCatalogEntries
            ))
        }
        agentExecution.proposal = nil
        agentExecution.assistantMessageID = nil
        store.dispatch(.clearChatHistory)
        pluginSession.packageMonitor?.setPackages(pluginPackageURLs())
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
        let imports = Set(try executor.requiredImports(forPluginID: pluginID).filter(\.isSnapshot))
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
                workspaceMode: store.state.content.rawValue,
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
