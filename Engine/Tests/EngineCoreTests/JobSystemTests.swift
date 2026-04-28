import EngineKernel
import Testing

@Suite("JobSystem")
struct JobSystemTests {
    @Test("parallelMap preserves input order and reports parallel dispatch")
    func parallelMapPreservesOrderAndReportsDispatch() {
        let jobSystem = JobSystem(workerCount: 4, minimumChunkSize: 1, label: "test.jobs.map")

        let (values, report) = jobSystem.parallelMap(items: Array(0..<8)) { value in
            value * value
        }

        #expect(values == [0, 1, 4, 9, 16, 25, 36, 49])
        #expect(report.jobCount == 4)
        #expect(report.workerCount == 4)
        #expect(report.executedInParallel)
    }
}
