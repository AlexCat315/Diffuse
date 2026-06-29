import EditorCore
import Foundation
import Testing

@Suite("EditorStore")
struct EditorStoreTests {
    @Test("No-op actions do not notify subscribers")
    func noOpActionsDoNotNotifySubscribers() {
        let store = EditorStore(state: EditorState(connected: true))
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

    @Test("Selection primary modifier behavior decodes legacy command key")
    func primaryModifierBehaviorDecodesLegacyCommandKey() throws {
        let data = Data(#"{"cmdSelectBehavior":"toggle"}"#.utf8)

        let state = try JSONDecoder().decode(EditorState.self, from: data)

        #expect(state.primarySelectBehavior == .toggle)
    }

    @Test("Selection primary modifier behavior encodes platform-neutral key")
    func primaryModifierBehaviorEncodesPlatformNeutralKey() throws {
        let state = EditorState(primarySelectBehavior: .toggle)

        let data = try JSONEncoder().encode(state)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains(#""primarySelectBehavior":"toggle""#))
        #expect(!json.contains("cmdSelectBehavior"))
    }

    @Test("Capability settings default when decoding legacy state")
    func capabilitySettingsDefaultWhenDecodingLegacyState() throws {
        let data = Data(#"{"connected":true}"#.utf8)

        let state = try JSONDecoder().decode(EditorState.self, from: data)

        #expect(state.capabilitySettings == .default)
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
        let state = EditorState(frameStatsHistory: [
            EditorFrameStatsHistorySample(sampleIndex: 1,
                                          frameIndex: 10,
                                          stats: EditorFrameStats(frameSeconds: 0.016)),
        ])

        let data = try JSONEncoder().encode(state)
        let json = String(decoding: data, as: UTF8.self)
        let decoded = try JSONDecoder().decode(EditorState.self, from: data)

        #expect(!json.contains("frameStatsHistory"))
        #expect(decoded.frameStatsHistory.isEmpty)
    }
}
