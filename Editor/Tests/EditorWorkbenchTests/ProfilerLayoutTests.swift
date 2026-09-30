import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import Testing
@testable import EditorApp

@Suite("Profiler dock layout", .serialized)
struct ProfilerLayoutTests {
    @Test("work budget does not count event-driven idle time as CPU work")
    func workBudgetExcludesIdleTime() {
        let sample = EditorFrameStatsHistorySample(
            sampleIndex: 1, frameIndex: 1,
            stats: EditorFrameStats(frameSeconds: 1, simulationSeconds: 0.003,
                                     gpuPresentSeconds: 0.001))
        let wallClock = developerProfilerFrameHealth(samples: [sample])
        let work = developerProfilerFrameHealth(samples: [sample], measuresWork: true)
        #expect(wallClock.averageWorkMs == 1000)
        #expect(wallClock.overBudgetCount == 1)
        #expect(work.averageWorkMs == 4)
        #expect(work.overBudgetCount == 0)
        #expect(work.budgetHitRate == 100)
    }

    @Test("live chart and summary fit a compact bottom dock",
          arguments: [(Float(640), Float(136)), (Float(960), Float(176))])
    func overviewFitsDock(size: (Float, Float)) throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let stats = EditorFrameStats(frameSeconds: 0.018, inputSeconds: 0.001,
                                     simulationSeconds: 0.002, renderPrepareSeconds: 0.003,
                                     renderSubmitSeconds: 0.001, gpuPresentSeconds: 0.004,
                                     drawCallCount: 128)
        let samples = (1...12).map {
            EditorFrameStatsHistorySample(sampleIndex: UInt64($0), frameIndex: UInt64($0), stats: stats)
        }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: DeveloperProfilerOverview(samples: samples, stats: stats)
            .theme(EditorVisualTheme.make(dark: false)))
        graph.computeLayout(width: size.0, height: size.1)
        let layout = graph.layoutSnapshot()
        let chart = try #require(layout.first { $0.debugName == "profiler-overview-chart" }?.absoluteFrame)
        let health = try #require(layout.first { $0.debugName == "profiler-overview-health" }?.absoluteFrame)
        let metrics = layout.filter { $0.debugName?.hasPrefix("profiler-metric-") == true }

        #expect(chart.width > 200)
        #expect(chart.height >= 24)
        #expect(chart.maxX <= health.minX)
        #expect(chart.maxY <= CGFloat(size.1))
        #expect(health.maxY <= CGFloat(size.1))
        #expect(metrics.count == 3)
        for metric in metrics {
            #expect(metric.absoluteFrame.width > 40)
            #expect(metric.absoluteFrame.maxY <= CGFloat(size.1))
        }
    } }
}
