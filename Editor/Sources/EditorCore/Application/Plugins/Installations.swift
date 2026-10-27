private import CoveFileSystem
public import Foundation
public import PluginRuntime

/// Application-owned installation decisions, separate from project-supplied files.
final class PluginInstallations: Sendable {
    struct Record: Codable, Sendable {
        let directory: String
        let authorization: PluginAuthorizationRecord
        var enabled: Bool
    }

    let root: URL
    static var applicationRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diffuse/InstalledPlugins", isDirectory: true)
    }

    init(root: URL = PluginInstallations.applicationRoot) { self.root = root.standardizedFileURL }

    func records() throws -> [Record] {
        let file = root.appendingPathComponent("registry.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let values = try JSONDecoder().decode([Record].self, from: Data(contentsOf: file))
        var ids = Set<String>()
        for record in values {
            guard ids.insert(record.authorization.pluginID).inserted,
                  record.directory.hasSuffix(".coveplugin"),
                  !record.directory.contains("/"), !record.directory.contains("\\"),
                  !record.directory.hasPrefix(".") else { throw PluginAuthorizationError.noLongerValid }
        }
        return values
    }

    func package(for record: Record) -> URL { root.appendingPathComponent(record.directory, isDirectory: true) }

    /// Copy first, then compare the copied bytes to the reviewed inspection.
    func stage(_ source: URL, inspection: PluginInspection) throws -> Record {
        let authorization = try PluginAuthorizationRecord(inspection: inspection)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let record = Record(directory: UUID().uuidString + ".coveplugin", authorization: authorization, enabled: false)
        let destination = package(for: record)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            let validated = try PluginPackageLoader().load(at: destination)
            let copied = PluginInspection(package: validated, contracts: PluginContractDeriver.contracts(for: validated))
            guard authorization.isStillValid(for: copied) else { throw PluginAuthorizationError.noLongerValid }
            return record
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func save(_ record: Record) throws {
        var values = try records()
        let previous = values.filter { $0.authorization.pluginID == record.authorization.pluginID && $0.directory != record.directory }
        values.removeAll { $0.authorization.pluginID == record.authorization.pluginID }
        values.append(record)
        try persist(values)
        for old in previous { try? FileManager.default.removeItem(at: package(for: old)) }
    }

    func setEnabled(_ enabled: Bool, ids: Set<String>) throws {
        var values = try records(), changed = false
        for index in values.indices where ids.contains(values[index].authorization.pluginID) && values[index].enabled != enabled {
            values[index].enabled = enabled; changed = true
        }
        if changed { try persist(values) }
    }

    func remove(id: String) throws {
        let values = try records()
        try persist(values.filter { $0.authorization.pluginID != id })
        // Keep package bytes until no running project can reference them.
        for record in values where record.authorization.pluginID == id {
            try? FileManager.default.removeItem(at: package(for: record))
        }
    }

    private func persist(_ values: [Record]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try AtomicFile.write(JSONEncoder().encode(values.sorted { $0.authorization.pluginID < $1.authorization.pluginID }),
                             to: root.appendingPathComponent("registry.json"), access: .ownerOnly)
    }
}

extension EditorApplication {
    @MainActor
    func restoreInstalledPlugins() async {
        guard let installations = pluginSession.editor.installations else { return }
        var failures: [String] = []
        do {
            var pending = try installations.records()
            // Deferred dependencies may be satisfied by another installed package.
            while !pending.isEmpty {
                var deferred: [PluginInstallations.Record] = []
                for record in pending {
                    let url = installations.package(for: record)
                    do {
                        let inspection = try await pluginSession.manager.install(at: url)
                        guard inspection.manifest.id == record.authorization.pluginID,
                              record.authorization.isStillValid(for: inspection) else { throw PluginAuthorizationError.noLongerValid }
                        if record.enabled { try await enablePlugin(at: url, authorization: record.authorization) }
                    } catch is UnmetPluginRequirements { deferred.append(record) }
                    catch { failures.append(Self.pluginManagementErrorMessage(error)) }
                }
                guard deferred.count < pending.count else {
                    failures.append("Installed plugins have unmet dependencies.")
                    break
                }
                pending = deferred
            }
            try await synchronizePlugins()
        } catch { failures.append(Self.pluginManagementErrorMessage(error)) }
        if !failures.isEmpty { publishPluginManagement(phase: .failed, candidate: nil, message: failures.joined(separator: "\n")) }
    }

    @MainActor
    func enableInstalledPackage(at url: URL, authorization: PluginAuthorizationRecord) async throws {
        var enabled: [EditorApplication] = []
        let applications = [self] + (pluginSession.editor.peers?() ?? []).filter { $0 !== self }
        do {
            for app in applications where app.enabledPluginManifests[authorization.pluginID] == nil {
                try await app.enablePlugin(at: url, authorization: authorization)
                enabled.append(app)
            }
            try pluginSession.editor.installations?.setEnabled(true, ids: [authorization.pluginID])
        } catch {
            for app in enabled { try? await app.disablePluginLocally(id: authorization.pluginID) }
            throw error
        }
    }
}
