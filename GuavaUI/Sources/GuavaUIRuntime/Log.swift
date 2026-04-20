import os.log

// TODO: abstract behind a protocol when GuavaUI targets non-Apple platforms.
extension Logger {
    static let runtime = Logger(subsystem: "com.guava.ui", category: "runtime")
}
