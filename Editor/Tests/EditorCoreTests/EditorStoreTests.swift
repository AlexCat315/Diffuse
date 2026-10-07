@testable import EditorCore
import Foundation
import ScriptRuntime
import Testing

@Suite("EditorStore")
struct EditorStoreTests {
    @Test("workbench navigation and running operations are not replayed from persisted state")
    func transientWorkbenchState() throws {
        let store = EditorStore()
        store.dispatch(.setOperation(.init(kind: .importing, message: "Importing")))
        store.dispatch(.navigateToScript(.init(scriptID: "Player", line: 3, column: 6)))
        store.dispatch(.setViewportMode(.game))
        store.dispatch(.setGamePreviewFocused(true))
        store.dispatch(.setGamePreviewResolution(.portrait))
        let data = try JSONEncoder().encode(store.state)
        let decoded = try JSONDecoder().decode(EditorState.self, from: data)
        #expect(decoded.navigation.operations.isEmpty)
        #expect(decoded.navigation.scriptNavigation == nil)
        #expect(decoded.viewport.mode == .scene)
        #expect(!decoded.viewport.gamePreviewFocused)
        #expect(decoded.viewport.gamePreviewResolution == .fit)
        let defaults = try JSONDecoder().decode(EditorViewportState.self, from: Data("{}".utf8))
        #expect(defaults.gamePreviewResolution == .fit)
    }

    @Test("compiler errors retain a clickable source line even without a language service")
    func compilerDiagnosticTarget() {
        let target = EditorIssueTarget.compilerDiagnostic(scriptID: "Player",
            sourceURL: URL(fileURLWithPath: "/project/Scripts/Player.swift"),
            output: "/project/Scripts/Player.swift:19:7: error: cannot find 'missing' in scope\n")
        #expect(target == .script(id: "Player", line: 18, column: 6))
    }

    @Test("unresolved export bindings locate the nested entity that needs repair")
    func unresolvedBindingTarget() {
        let child = EditorSceneManifestNode(id: 42, name: "Player: Main", kind: "empty",
            script: EditorSceneManifestScript(ScriptComponent(ScriptBinding(identifier: "game.missing"))))
        let root = EditorSceneManifestNode(id: 1, name: "Root", kind: "empty", children: [child])
        let manifest = EditorSceneManifest(revision: 0, entityCount: 2, roots: [root])
        #expect(EditorIssueTarget.unresolvedBindingTarget(["Player: Main: game.missing"], in: manifest) == .entity(id: 42))
        #expect(EditorIssueTarget.unresolvedBindingTarget(["Unknown: game.missing"], in: manifest) == nil)
    }

    @Test("No-op actions do not notify subscribers")
    func noOpActionsDoNotNotifySubscribers() {
        let store = EditorStore(state: EditorState {
            $0.timing.connected = true
        })
        var notifications = 0
        _ = store.subscribe { _ in notifications += 1 }

        store.dispatch(.setConnected(true))

        #expect(store.version == 0)
        #expect(notifications == 0)
    }

    @Test("Changed actions increment version and notify subscribers")
    func changedActionsNotifySubscribers() {
        let store = EditorStore()
        var notifications = 0
        _ = store.subscribe { _ in notifications += 1 }

        store.dispatch(.setConnected(true))

        #expect(store.version == 1)
        #expect(notifications == 1)
        #expect(store.connected)
    }

    @Test("recovered autosaves stay dirty until an explicit save")
    func recoveredAutosaveDirtyState() {
        let store = EditorStore(state: EditorState {
            $0.document.sceneRevision = 12
            $0.document.lastSavedSceneRevision = 12
        })
        #expect(!store.sceneDirty)

        store.dispatch(.setSceneRecoveryPending(true))
        #expect(store.sceneDirty)
        #expect(store.sceneRecoveryPending)

        store.dispatch(.markSceneSaved(12))
        #expect(!store.sceneDirty)
        #expect(!store.sceneRecoveryPending)
    }

    @Test("Console changes notify subscribers")
    func consoleChangesNotifySubscribers() {
        let store = EditorStore()
        var notifications = 0
        _ = store.subscribe { _ in notifications += 1 }

        store.dispatch(.appendConsoleMessage("Built project"))

        #expect(store.version == 1)
        #expect(notifications == 1)
        #expect(store.latestConsoleEntry?.message == "Built project")
    }

    @Test("Selection primary modifier behavior decodes grouped state")
    func primaryModifierBehaviorDecodesGroupedState() throws {
        let data = Data(#"{"selection":{"primarySelectBehavior":"toggle"}}"#.utf8)

        let state = try JSONDecoder().decode(EditorState.self, from: data)

        #expect(state.selection.primarySelectBehavior == .toggle)
    }

    @Test("Selection primary modifier behavior encodes platform-neutral key")
    func primaryModifierBehaviorEncodesPlatformNeutralKey() throws {
        let state = EditorState {
            $0.selection.primarySelectBehavior = .toggle
        }

        let data = try JSONEncoder().encode(state)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains(#""primarySelectBehavior":"toggle""#))
        #expect(!json.contains("cmdSelectBehavior"))
    }

    @Test("Unspecified editor groups use their own defaults")
    func unspecifiedGroupsUseDefaults() throws {
        let data = Data(#"{"timing":{"connected":true}}"#.utf8)

        let state = try JSONDecoder().decode(EditorState.self, from: data)

        #expect(state.assistant.capabilitySettings == .default)
        #expect(state.viewport.physicsDebugOverlayOptions == .all)
        #expect(state.viewport.physicsDebugOverlayScope == .selected)
    }

    @Test("physics debug overlay options and scope persist and notify subscribers")
    func physicsDebugOptionsPersistAndNotify() throws {
        let store = EditorStore()
        var notifications = 0
        _ = store.subscribe { _ in notifications += 1 }
        let options: EditorPhysicsDebugOverlayOptions = [.shapes, .joints]

        store.dispatch(.setPhysicsDebugOverlayOptions(options))
        store.dispatch(.setPhysicsDebugOverlayScope(.scene))

        #expect(store.physicsDebugOverlayOptions == options)
        #expect(store.physicsDebugOverlayScope == .scene)
        #expect(notifications == 2)
        let data = try JSONEncoder().encode(store.state)
        let restored = try JSONDecoder().decode(EditorState.self, from: data)
        #expect(restored.viewport.physicsDebugOverlayOptions == options)
        #expect(restored.viewport.physicsDebugOverlayScope == .scene)
    }

    @Test("Capability settings notify subscribers")
    func capabilitySettingsNotifySubscribers() {
        let store = EditorStore()
        var notifications = 0
        _ = store.subscribe { _ in notifications += 1 }

        store.dispatch(.setCapabilitySettings(EditorCapabilitySettings(releasePhase: .experimental)))

        #expect(store.version == 1)
        #expect(notifications == 1)
        #expect(store.capabilitySettings.releasePhase == .experimental)
    }

    @Test("Frame stats separate tick gap from actual frame work")
    func frameStatsSeparateTickGapFromWork() {
        let stats = EditorFrameStats(frameSeconds: 0.410,
                                     inputSeconds: 0,
                                     simulationSeconds: 0.00069,
                                     renderPrepareSeconds: 0,
                                     renderSubmitSeconds: 0.00862,
                                     gpuPresentSeconds: 0.00862)

        #expect(abs(stats.frameMs - 410) < 0.001)
        #expect(abs(stats.workMs - 17.93) < 0.001)
        #expect(abs(stats.pacingGapMs - 392.07) < 0.001)
        #expect(stats.isFramePacingDominated)
        #expect(stats.fps < 3)
        #expect(stats.workFPS > 55)
    }

    @Test("Frame stats updates maintain a bounded diagnostic history")
    func frameStatsHistoryIsBounded() {
        let store = EditorStore()
        var notifications = 0
        _ = store.subscribe { _ in notifications += 1 }

        let sampleCount = EditorState.maxFrameStatsHistorySamples + 5
        for index in 1...sampleCount {
            store.dispatch(.tickFrame(UInt64(index)))
            store.dispatch(.updateFrameStats(EditorFrameStats(frameSeconds: Double(index) / 1_000,
                                                              drawCallCount: index)))
        }

        #expect(store.frameStatsHistory.count == EditorState.maxFrameStatsHistorySamples)
        #expect(store.frameStatsHistory.first?.sampleIndex == 6)
        #expect(store.frameStatsHistory.first?.frameIndex == 6)
        #expect(store.frameStatsHistory.last?.sampleIndex == UInt64(sampleCount))
        #expect(store.frameStatsHistory.last?.frameIndex == UInt64(sampleCount))
        #expect(store.frameStatsHistory.last?.stats.drawCallCount == sampleCount)
        #expect(notifications == sampleCount)
    }

    @Test("Frame stats history is transient editor state")
    func frameStatsHistoryIsTransient() throws {
        let state = EditorState {
            $0.timing.frameStatsHistory = [
            EditorFrameStatsHistorySample(sampleIndex: 1,
                                          frameIndex: 10,
                                          stats: EditorFrameStats(frameSeconds: 0.016)),
        ]
        }

        let data = try JSONEncoder().encode(state)
        let json = String(decoding: data, as: UTF8.self)
        let decoded = try JSONDecoder().decode(EditorState.self, from: data)

        #expect(!json.contains("frameStatsHistory"))
        #expect(decoded.timing.frameStatsHistory.isEmpty)
    }

    @Test("Particle diagnostics maintain a bounded transient history")
    func particleDiagnosticsHistoryIsBoundedAndTransient() throws {
        let store = EditorStore()
        var notifications = 0
        _ = store.subscribe { _ in notifications += 1 }

        let sampleCount = EditorState.maxParticleDiagnosticsHistorySamples + 3
        for index in 1...sampleCount {
            store.dispatch(.tickFrame(UInt64(index)))
            store.dispatch(.updateParticleDiagnostics(
                EditorParticleDiagnosticsSample(sampleIndex: UInt64(index),
                                                frameIndex: UInt64(index),
                                                simulatedDeltaTime: 1.0 / 60.0,
                                                emitterCount: 1,
                                                activeEmitterCount: 1,
                                                liveParticleCount: index,
                                                liveParticleLimit: 1_000,
                                                requestedSpawnCount: index,
                                                spawnedParticleCount: index,
                                                droppedSpawnCount: 0,
                                                capacityLimitedSpawnCount: 0,
                                                spawnBudgetLimitedCount: 0,
                                                spawnBudgetConsumedCount: index,
                                                spawnBudgetLimit: 0,
                                                eventRequestedSpawnCount: 0,
                                                eventDroppedSpawnCount: 0,
                                                droppedReadbackEventCount: 0,
                                                cpuRenderInstanceCount: index,
                                                gpuRenderInstanceCount: 0,
                                                cpuBatchCount: 1,
                                                gpuBatchCount: 0,
                                                gpuSimulationParticleCount: 0,
                                                gpuWorkgroupCount: 0,
                                                gpuSortItemCount: 0,
                                                gpuSortPaddedItemCount: 0)
            ))
        }

        #expect(store.particleDiagnosticsHistory.count == EditorState.maxParticleDiagnosticsHistorySamples)
        #expect(store.particleDiagnosticsHistory.first?.sampleIndex == 4)
        #expect(store.particleDiagnosticsHistory.first?.frameIndex == 4)
        #expect(store.particleDiagnosticsHistory.last?.sampleIndex == UInt64(sampleCount))
        #expect(store.particleDiagnosticsHistory.last?.liveParticleCount == sampleCount)
        #expect(notifications == sampleCount)

        let data = try JSONEncoder().encode(store.state)
        let json = String(decoding: data, as: UTF8.self)
        let decoded = try JSONDecoder().decode(EditorState.self, from: data)

        #expect(!json.contains("particleDiagnosticsHistory"))
        #expect(decoded.timing.particleDiagnosticsHistory.isEmpty)
    }
}
