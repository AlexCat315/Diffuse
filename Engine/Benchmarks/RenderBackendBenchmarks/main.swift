import Foundation
import NativeRendererValidation

// Use the same native workload, completion and readback accounting as the pass probe.
var arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.contains("--scene") { arguments = ["--scene", "mesh"] + arguments }
do { try NativePassBenchmark.run(arguments: arguments) }
catch {
    FileHandle.standardError.write(Data("renderer benchmark failed: \(error)\n".utf8))
    exit(1)
}
