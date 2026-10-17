package import Foundation

#if canImport(Darwin)
  private import Darwin
#elseif canImport(Glibc)
  private import Glibc
#endif

package enum ProcessSignal {
  package static func kill(_ process: Process) {
    guard process.isRunning else { return }
    #if canImport(Darwin)
      Darwin.kill(process.processIdentifier, SIGKILL)
    #elseif canImport(Glibc)
      Glibc.kill(process.processIdentifier, SIGKILL)
    #else
      process.terminate()
    #endif
  }
}
