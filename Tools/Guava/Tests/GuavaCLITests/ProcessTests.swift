import Foundation
import Testing
import GuavaLogging
@testable import GuavaCLI

#if !os(Windows)
@Test func childStreamsDrainConcurrentlyAndMachineStdoutStaysPrivate() throws {
    let marker = UUID().uuidString
    let output = try Shell.run(["/bin/sh", "-c", "i=0; while [ $i -lt 12000 ]; do printf 'machine-data-0123456789\\n'; i=$((i+1)); done; printf 'stream-\(marker)\\n' >&2"], capture: true, quiet: true)
    #expect(output.split(separator: "\n").count == 12000)
    LogSystem.flush()
    let records = LogSystem.snapshot().records
    #expect(records.contains { $0.message == "stream-\(marker)" && $0.location.source == "process.stderr" })
    #expect(!records.contains { $0.message.contains("machine-data-0123456789") })
    let inherited = try Shell.run(["/usr/bin/env"], capture: true, quiet: true)
    #expect(inherited.contains("GUAVA_LOG_RUN_ID=" + LogSystem.launch.runID))
}
#endif
