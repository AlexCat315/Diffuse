import Foundation
import NativeRendererValidation

do { try GridPassBenchmark.run(arguments: Array(CommandLine.arguments.dropFirst())) }
catch { FileHandle.standardError.write(Data("NativeRHIPassProbe: \(error)\n".utf8)); exit(1) }
