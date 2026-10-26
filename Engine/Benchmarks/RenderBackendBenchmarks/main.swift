import Foundation
import CoveLogging
private var loggingConfiguration = LoggingConfiguration()
try loggingConfiguration.applyEnvironment(ProcessInfo.processInfo.environment)
try LogSystem.bootstrap(configuration: loggingConfiguration)
defer { LogSystem.flush() }
import NativeRendererValidation

// Use the same native workload, completion and readback accounting as the pass probe.
var arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.contains("--scene") { arguments = ["--scene", "mesh"] + arguments }
do { try NativePassBenchmark.run(arguments: arguments) }
catch {
    LogSystem.logger("com.cove.tools").error("renderer benchmark failed: \(error)")
        LogSystem.flush()
    exit(1)
}
