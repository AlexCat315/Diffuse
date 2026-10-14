import Foundation
import GuavaLogging
private var loggingConfiguration = LoggingConfiguration()
try loggingConfiguration.applyEnvironment(ProcessInfo.processInfo.environment)
try LogSystem.bootstrap(configuration: loggingConfiguration)
defer { LogSystem.flush() }
import NativeRendererValidation

do { try NativePassBenchmark.run(arguments: Array(CommandLine.arguments.dropFirst())) }
catch { LogSystem.logger("com.guava.tools").error("NativeRHIPassProbe: \(error)")
        LogSystem.flush(); exit(1) }
