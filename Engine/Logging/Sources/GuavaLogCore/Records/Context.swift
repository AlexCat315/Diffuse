import Logging

public enum LogContext {
    public static var current: Logger.Metadata { metadata }
    @TaskLocal package static var metadata: Logger.Metadata = [:]
    public static func withValues<T>(_ values: Logger.Metadata, operation: () throws -> T) rethrows -> T {
        try $metadata.withValue(metadata.merging(values) { _, new in new }, operation: operation)
    }
    public nonisolated(nonsending) static func withValues<T>(_ values: Logger.Metadata, operation: () async throws -> T) async rethrows -> T {
        try await $metadata.withValue(metadata.merging(values) { _, new in new }, operation: operation)
    }
}
