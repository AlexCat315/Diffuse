import Foundation
@testable import PluginRuntime
import Testing

@Suite("Plugin lifecycle") @MainActor
struct PluginManagerTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var values: [String] { lock.withLock { recorded } }
        func add(_ value: String) { lock.withLock { recorded.append(value) } }
    }

    private actor ActivationGate {
        var started = false
        var waiting: CheckedContinuation<Void, Never>?
        var resumed: CheckedContinuation<Void, Never>?
        func pause() async {
            started = true; waiting?.resume(); waiting = nil
            await withCheckedContinuation { resumed = $0 }
        }
        func waitForStart() async {
            if !started { await withCheckedContinuation { waiting = $0 } }
        }
        func release() { resumed?.resume(); resumed = nil }
    }

    private func package(id: String = "fixture.lazy", runtime: Bool = true,
                         events: [String] = [], requires: [PluginRequirement] = []) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".coveplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var manifest = CovePluginManifest(id: id, version: 1, name: id, description: "Fixture", access: .read,
                                          requires: requires)
        manifest.activation = events
        if runtime { manifest.runtime = .init() }
        if !runtime {
            try manifest.contributes.set(LanguageContributionPoint.self,
                descriptors: [LanguageContribution(id: "fixture", title: "Fixture", extensions: ["fixture"])])
        }
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("plugin.json"))
        if runtime {
            try Data("export default {}".utf8).write(to: root.appendingPathComponent("plugin.js"))
            try Data(#"{"version":1,"entries":[{"name":"inspect","title":"Inspect","description":"","input":{"record":{"enabled":"bool"}}}]}"#.utf8).write(to: root.appendingPathComponent("capabilities.json"))
        }
        return root
    }

    private func authorize(_ url: URL) throws -> PluginAuthorizationRecord {
        let package = try PluginPackageLoader().load(at: url)
        return try PluginAuthorizationRecord(inspection: PluginInspection(package: package,
            contracts: PluginContractDeriver.contracts(for: package)))
    }

    private func driver(_ calls: Calls, failing: String? = nil) -> PluginRuntimeDriver {
        PluginRuntimeDriver(activate: { url, authorization in
            let package = try PluginPackageLoader().load(at: url)
            calls.add("activate:" + package.manifest.id)
            if package.manifest.id == failing { throw PluginManagerError.runtimeUnavailable }
            let binding = try PluginExecutionBinding(pluginPath: url.path,
                inspection: PluginInspection(package: package, contracts: PluginContractDeriver.contracts(for: package)),
                authorization: authorization, hostGeneration: 1)
            return PluginRuntimeActivation(binding: binding)
        }, deactivate: { calls.add("deactivate:" + $0.pluginID) }, stop: { calls.add("stop") })
    }

    @Test("registrations release in reverse order, once, even when release throws")
    func disposal() throws {
        let calls = Calls(), scope = DisposalScope()
        try scope.own(Registration { calls.add("first") })
        try scope.own(Registration { calls.add("second"); throw PluginManagerError.runtimeUnavailable })
        try scope.own(Registration { calls.add("third") })
        #expect(throws: PluginManagerError.runtimeUnavailable) { try scope.dispose() }
        try scope.dispose()
        try scope.own(Registration { calls.add("late") })
        #expect(calls.values == ["third", "second", "first", "late"])
    }

    @Test("enabled declarations survive without a host and disappear on disable")
    func declarations() async throws {
        let url = try package(runtime: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let catalog = ContributionCatalog<LanguageContribution>()
        var registrar = ContributionRegistrar()
        try registrar.register(LanguageContributionPoint.self) { values, package in
            try catalog.register(values, pluginID: package.manifest.id)
        }
        let manager = PluginManager(registrar: registrar)
        _ = try await manager.install(at: url)
        #expect(manager.statuses.first?.phase == .installed)
        _ = try await manager.enable(at: url, authorization: authorize(url))
        #expect(manager.statuses.first?.phase == .enabled)
        #expect(catalog.snapshot.values.count == 1)
        try await manager.reload(id: "fixture.lazy")
        #expect(catalog.snapshot.values.count == 1)
        try await manager.disable(id: "fixture.lazy")
        #expect(catalog.snapshot.values.isEmpty)
        #expect(manager.statuses.first?.phase == .installed)
        try await manager.uninstall(id: "fixture.lazy")
        #expect(manager.statuses.isEmpty)
    }

    @Test("runtime stays dormant until demand and concurrent demand activates once")
    func lazyActivation() async throws {
        let url = try package(events: ["onView:fixture"])
        defer { try? FileManager.default.removeItem(at: url) }
        let calls = Calls(), manager = PluginManager(registrar: ContributionRegistrar())
        manager.configureRuntime(driver(calls))
        _ = try await manager.enable(at: url, authorization: authorize(url))
        try await manager.reload(id: "fixture.lazy")
        try await manager.activate(event: "onLanguage:other")
        #expect(calls.values.isEmpty)
        let first = Task { try await manager.activate(event: "onView:fixture") }
        let second = Task { try await manager.activate(event: "onView:fixture") }
        try await first.value; try await second.value
        #expect(calls.values == ["activate:fixture.lazy"])
        #expect(manager.statuses.first?.phase == .activated)
        try await manager.disable(id: "fixture.lazy")
        #expect(calls.values == ["activate:fixture.lazy", "deactivate:fixture.lazy"])
    }

    @Test("dependency demand activates providers first; failure withdraws dependents only")
    func dependencyActivation() async throws {
        let provider = try package(id: "fixture.provider")
        let dependent = try package(id: "fixture.dependent", requires: [.init(kind: .capability, id: "fixture.provider.inspect")])
        let data = try package(id: "fixture.data", runtime: false)
        defer { for url in [provider, dependent, data] { try? FileManager.default.removeItem(at: url) } }
        let catalog = ContributionCatalog<LanguageContribution>()
        var registrar = ContributionRegistrar()
        try registrar.register(LanguageContributionPoint.self) { values, package in
            try catalog.register(values, pluginID: package.manifest.id)
        }
        let calls = Calls(), manager = PluginManager(registrar: registrar)
        manager.configureRuntime(driver(calls, failing: "fixture.provider"))
        for url in [provider, dependent, data] { _ = try await manager.enable(at: url, authorization: authorize(url)) }
        do { _ = try await manager.activate(id: "fixture.dependent"); Issue.record("activation must fail") }
        catch PluginManagerError.runtimeUnavailable {}
        #expect(manager.enabledManifests.keys.sorted() == ["fixture.data"])
        #expect(catalog.snapshot.values.count == 1)
        #expect(calls.values == ["activate:fixture.provider"])
        #expect(manager.statuses.filter { $0.phase == .failed }.count == 2)
    }

    @Test("disabling an owner withdraws dependent plugins before the owner")
    func disableCascades() async throws {
        let provider = try package(id: "fixture.provider")
        let dependent = try package(id: "fixture.dependent", requires: [.init(kind: .plugin, id: "fixture.provider")])
        defer { for url in [provider, dependent] { try? FileManager.default.removeItem(at: url) } }
        let calls = Calls(), manager = PluginManager(registrar: ContributionRegistrar())
        manager.configureRuntime(driver(calls))
        for url in [provider, dependent] { _ = try await manager.enable(at: url, authorization: authorize(url)) }
        _ = try await manager.activate(id: "fixture.dependent")
        try await manager.disable(id: "fixture.provider")
        #expect(manager.enabledManifests.isEmpty)
        #expect(calls.values.suffix(2) == ["deactivate:fixture.dependent", "deactivate:fixture.provider"])
    }

    @Test("startup remembered before enable; workspace globs and URI events route precisely")
    func rememberedEvents() async throws {
        let url = try package(events: ["onStartup"])
        defer { try? FileManager.default.removeItem(at: url) }
        let calls = Calls(), manager = PluginManager(registrar: ContributionRegistrar())
        manager.configureRuntime(driver(calls))
        try await manager.activate(event: "onStartup")
        _ = try await manager.enable(at: url, authorization: authorize(url))
        #expect(manager.statuses.first?.phase == .activated)
        #expect(PluginManager.matches("onWorkspaceContains:**/Package.*", "onWorkspaceContains:App/Package.swift"))
        #expect(!PluginManager.matches("onURI:cove", "onURI:other"))
        #expect(!PluginActivationEvent.isValid("onView:"))
    }

    @Test("registration failure rolls back preceding domain registrations")
    func registrationRollback() async throws {
        let url = try package(runtime: false)
        defer { try? FileManager.default.removeItem(at: url) }
        var manifest = try PluginPackageLoader().load(at: url).manifest
        try manifest.contributes.set(AIProviderContributionPoint.self, descriptors: [
            AIProviderContribution(id: "fixture", title: "Fixture", apiFormat: "openai-compatible",
                models: [AIModelContribution(id: "fixture", title: "Fixture")])
        ])
        try JSONEncoder().encode(manifest).write(to: url.appendingPathComponent("plugin.json"))
        let calls = Calls()
        var registrar = ContributionRegistrar()
        try registrar.register(AIProviderContributionPoint.self) { _, _ in
            calls.add("register:provider")
            return Registration { calls.add("dispose:provider") }
        }
        try registrar.register(LanguageContributionPoint.self) { _, _ in
            calls.add("register:language")
            throw PluginManagerError.runtimeUnavailable
        }
        let manager = PluginManager(registrar: registrar)
        do { _ = try await manager.enable(at: url, authorization: authorize(url)); Issue.record("registration must fail") }
        catch PluginManagerError.runtimeUnavailable {}
        #expect(manager.enabledInspections.isEmpty)
        #expect(manager.statuses.first?.phase == .failed)
        #expect(calls.values == ["register:provider", "register:language", "dispose:provider"])
    }

    @Test("stop during activation cannot resurrect a binding")
    func stopDuringActivation() async throws {
        let url = try package()
        defer { try? FileManager.default.removeItem(at: url) }
        let calls = Calls(), gate = ActivationGate(), base = driver(calls)
        let manager = PluginManager(registrar: ContributionRegistrar())
        manager.configureRuntime(PluginRuntimeDriver(activate: { url, authorization in
            let binding = try await base.activate(url, authorization)
            await gate.pause()
            return binding
        }, deactivate: base.deactivate, stop: base.stop))
        _ = try await manager.enable(at: url, authorization: authorize(url))
        let activation = Task { try await manager.activate(id: "fixture.lazy") }
        await gate.waitForStart()
        manager.stop()
        await gate.release()
        do { _ = try await activation.value; Issue.record("stopped activation must fail") }
        catch PluginAuthorizationError.noLongerValid {}
        #expect(manager.statuses.isEmpty)
        #expect(manager.activeBindings.isEmpty)
        #expect(calls.values == ["activate:fixture.lazy", "stop", "deactivate:fixture.lazy"])
    }

    @Test("runtime invalidation releases dependents before providers and leaves data enabled")
    func runtimeInvalidation() async throws {
        let provider = try package(id: "fixture.provider")
        let dependent = try package(id: "fixture.dependent", requires: [.init(kind: .plugin, id: "fixture.provider")])
        let data = try package(id: "fixture.data", runtime: false)
        defer { for url in [provider, dependent, data] { try? FileManager.default.removeItem(at: url) } }
        var registrar = ContributionRegistrar()
        try registrar.register(LanguageContributionPoint.self) { _, _ in Registration {} }
        let calls = Calls(), manager = PluginManager(registrar: registrar)
        manager.configureRuntime(driver(calls))
        for url in [provider, dependent, data] { _ = try await manager.enable(at: url, authorization: authorize(url)) }
        _ = try await manager.activate(id: "fixture.dependent")
        #expect(calls.values == ["activate:fixture.provider", "activate:fixture.dependent"])
        #expect(await manager.invalidateRuntime(before: 1) == false)
        #expect(manager.activeBindings.count == 2)
        #expect(await manager.invalidateRuntime(before: 2))
        #expect(manager.enabledManifests.keys.sorted() == ["fixture.data"])
        #expect(calls.values.suffix(2) == ["deactivate:fixture.dependent", "deactivate:fixture.provider"])
    }
}
