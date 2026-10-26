public import Foundation
internal import CoveProcess
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public struct SwiftToolchainRelease: Sendable, Equatable, Identifiable {
    public let version: String
    public let downloadURL: URL
    public var id: String { version }
}

public enum SwiftToolchainInstallProgress: Sendable, Equatable {
    case downloading(receivedBytes: Int64, totalBytes: Int64?)
    case verifying
    case installing
    case completed(URL)
    case cancelled
    case failed(String)
}

public actor SwiftToolchainInstallation {
    public static var releases: [SwiftToolchainRelease] {
        #if os(macOS) && (arch(arm64) || arch(x86_64))
        ["6.4.1", "6.4.0"].map { version in
            SwiftToolchainRelease(version: version, downloadURL: URL(string:
                "https://download.swift.org/swift-\(version)-release/xcode/swift-\(version)-RELEASE/swift-\(version)-RELEASE-osx.pkg")!)
        }
        #else
        []
        #endif
    }

    private let directory: URL
    private var isInstalling = false

    public init(directory: URL = SwiftToolchainPreferences.directory) {
        self.directory = directory
    }

    public func install(version: String, confirmed: Bool,
                        onProgress: @escaping @Sendable (SwiftToolchainInstallProgress) -> Void) async throws -> SwiftToolchain {
        guard confirmed else { throw SwiftToolchainError.confirmationRequired }
        guard let release = Self.releases.first(where: { $0.version == version }) else {
            throw SwiftToolchainError.unsupportedPlatform
        }
        guard !isInstalling else { throw SwiftToolchainError.installationInProgress }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let lease = try SwiftToolchainInstallLease(directory: directory)
        isInstalling = true
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)")
        defer {
            isInstalling = false
            try? fileManager.removeItem(at: staging)
            lease.close()
        }
        do {
            try Task.checkCancellation()
            for child in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where child.lastPathComponent.hasPrefix(".staging-") && child != staging {
                try fileManager.removeItem(at: child)
            }
            let destination = installURL(version: release.version)
            guard !fileManager.fileExists(atPath: destination.path) else {
                let toolchain = try SwiftToolchainResolver.resolve(compilerOverride: destination.path)
                onProgress(.completed(destination))
                return toolchain
            }
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            let archive = staging.appendingPathComponent("toolchain.pkg")
            onProgress(.downloading(receivedBytes: 0, totalBytes: nil))
            let delegate = SwiftToolchainDownload(progress: onProgress)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 7200
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (download, response) = try await session.download(from: release.downloadURL, delegate: delegate)
            defer { try? fileManager.removeItem(at: download) }
            try Self.validateResponse(response)
            try Task.checkCancellation()
            try fileManager.moveItem(at: download, to: archive)
            onProgress(.verifying)
            try await verify(archive)
            try Task.checkCancellation()
            onProgress(.installing)
            let expanded = staging.appendingPathComponent("Expanded")
            try await run("/usr/sbin/pkgutil", arguments: ["--expand-full", archive.path, expanded.path])
            try Task.checkCancellation()
            let payload = try Self.payload(in: expanded)
            let toolchain = try SwiftToolchainResolver.resolve(compilerOverride: payload.path)
            guard toolchain.version.contains("Swift version \(release.version)") else {
                throw SwiftToolchainError.invalidInstallation("The downloaded toolchain version does not match Swift \(release.version).")
            }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Task.checkCancellation()
            try fileManager.moveItem(at: payload, to: destination)
            let installed: SwiftToolchain
            do { installed = try SwiftToolchainResolver.resolve(compilerOverride: destination.path) }
            catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
            onProgress(.completed(destination))
            return installed
        } catch {
            if Task.isCancelled || error is CancellationError {
                onProgress(.cancelled)
                throw CancellationError()
            }
            onProgress(.failed(error.localizedDescription))
            throw error
        }
    }

    public func remove(version: String) throws {
        guard Self.releases.contains(where: { $0.version == version }) else { throw SwiftToolchainError.unsupportedPlatform }
        guard !isInstalling else {
            throw SwiftToolchainError.installationInProgress
        }
        let lease = try SwiftToolchainInstallLease(directory: directory)
        defer { lease.close() }
        let target = installURL(version: version)
        if let selected = SwiftToolchainPreferences.load(from: directory).selectedPath,
           URL(fileURLWithPath: selected).standardizedFileURL.path.hasPrefix(target.standardizedFileURL.path) {
            throw SwiftToolchainError.invalidInstallation("Select another toolchain before removing the active toolchain.")
        }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }

    public func installedVersions() -> [String] {
        Self.releases.map(\.version).filter { FileManager.default.fileExists(atPath: installURL(version: $0).path) }
    }

    private func installURL(version: String) -> URL {
        directory.appendingPathComponent("Installed/swift-\(version).xctoolchain", isDirectory: true)
    }

    private func verify(_ archive: URL) async throws {
        let output = try await run("/usr/sbin/pkgutil", arguments: ["--check-signature", archive.path])
        guard Self.isOfficialSignature(String(decoding: output.stdout + output.stderr, as: UTF8.self)) else {
            throw SwiftToolchainError.invalidInstallation("The Swift download does not have a trusted Swift Open Source installer signature.")
        }
    }

    static func isOfficialSignature(_ output: String) -> Bool {
        output.contains("Status: signed by a certificate trusted")
            && output.contains("1. Developer ID Installer: Swift Open Source (V9AUD2URP3)")
    }

    static func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = http.url, url.scheme == "https", url.host == "download.swift.org" else {
            throw SwiftToolchainError.invalidInstallation("The Swift download did not return a successful response from download.swift.org.")
        }
    }

    private static func payload(in expanded: URL) throws -> URL {
        let fileManager = FileManager.default
        guard let files = fileManager.enumerator(at: expanded, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            throw SwiftToolchainError.invalidInstallation("The Swift package payload is missing.")
        }
        var toolchains = [URL]()
        for case let candidate as URL in files where candidate.pathExtension == "xctoolchain" {
            let attributes = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if attributes.isDirectory == true, attributes.isSymbolicLink != true {
                toolchains.append(candidate)
                files.skipDescendants()
            }
        }
        guard toolchains.count == 1, let toolchain = toolchains.first else {
            throw SwiftToolchainError.invalidInstallation("The Swift package must contain exactly one toolchain.")
        }
        return toolchain
    }

    @discardableResult
    private func run(_ executable: String, arguments: [String]) async throws -> ProcessOutput {
        var command = ProcessCommand(executable: URL(fileURLWithPath: executable), directory: directory)
        command.arguments = arguments
        command.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C", "LANG": "C"]) { _, new in new }
        var budget = ProcessBudget()
        budget.lifetimeMilliseconds = 900_000
        budget.outputBytes = 1_048_576
        let output = try await ProcessRunner.run(command, budget: budget)
        guard output.status == 0 else {
            throw SwiftToolchainError.invalidInstallation(String(decoding: output.stderr + output.stdout, as: UTF8.self))
        }
        return output
    }
}

private struct SwiftToolchainInstallLease {
    let descriptor: Int32

    init(directory: URL) throws {
        #if os(macOS) || os(Linux)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(".installation-lock")
        descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SwiftToolchainError.installationInProgress }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Self.closeDescriptor(descriptor)
            throw SwiftToolchainError.installationInProgress
        }
        #else
        throw SwiftToolchainError.unsupportedPlatform
        #endif
    }

    func close() { Self.closeDescriptor(descriptor) }

    private static func closeDescriptor(_ descriptor: Int32) {
        #if os(macOS)
        _ = Darwin.close(descriptor)
        #elseif os(Linux)
        _ = Glibc.close(descriptor)
        #endif
    }
}

private final class SwiftToolchainDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (SwiftToolchainInstallProgress) -> Void

    init(progress: @escaping @Sendable (SwiftToolchainInstallProgress) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == "download.swift.org" ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 8_589_934_592 { downloadTask.cancel(); return }
        progress(.downloading(receivedBytes: totalBytesWritten,
                              totalBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
