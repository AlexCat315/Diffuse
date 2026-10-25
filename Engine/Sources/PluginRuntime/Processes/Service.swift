public import Foundation
private import GuavaProcess

/// Stores native resources outside short-lived WASM Stores. Every operation is
/// scoped to an approved mount generation; unload invalidates all its handles.
public final class PluginProcessService: @unchecked Sendable {
    private struct Mount {
        let generation: UUID
        let permissions: PluginHostPermissions
        let context: PluginProcessContext
    }
    private let lock = NSLock()
    private var mounts: [String: Mount] = [:]
    private var processes: [UUID: ProcessEntry] = [:]

    public init() {}
    deinit { processes.values.forEach { $0.session.cancel() } }

    public func mount(inspection: PluginInspection, authorization: PluginAuthorizationRecord,
                      context: PluginProcessContext) throws {
        guard authorization.isStillValid(for: inspection) else { throw PluginAuthorizationError.noLongerValid }
        try inspection.manifest.host.validate(imports: inspection.manifest.imports)
        unmount(pluginID: inspection.manifest.id)
        lock.withLock {
            mounts[inspection.manifest.id] = Mount(generation: UUID(), permissions: inspection.manifest.host, context: context)
        }
    }

    public func unmount(pluginID: String) {
        let removed: [ProcessEntry] = lock.withLock {
            guard let mount = mounts.removeValue(forKey: pluginID) else { return [] }
            let entries = processes.values.filter { $0.generation == mount.generation }
            for entry in entries { processes.removeValue(forKey: entry.session.id) }
            return entries
        }
        removed.forEach { $0.session.cancel() }
    }

    public func response(pluginID: String, entryPoint: String, request: Data) throws -> Data {
        guard request.count <= PluginQuerySnapshot.maximumRequestBytes else { throw PluginProcessError.invalidRequest }
        let input = try JSONDecoder().decode(PluginProcessRequest.self, from: request)
        return try JSONEncoder().encode(perform(pluginID: pluginID, entryPoint: entryPoint, request: input))
    }

    public func perform(pluginID: String, entryPoint: String, request: PluginProcessRequest) throws -> PluginProcessUpdate {
        try lock.withLock {
            guard let mount = mounts[pluginID] else { throw PluginProcessError.notAuthorized }
            if request.operation == .start {
                guard let rule = mount.permissions.processes.first(where: { $0.id == request.permission }),
                      rule.entryPoints.contains(entryPoint) else {
                    throw PluginProcessError.notAuthorized
                }
                guard processes.values.filter({ $0.generation == mount.generation }).count < 8,
                      processes.count < 32 else { throw PluginProcessError.processLimit }
                guard let executable = mount.context.executables[rule.command], executable.isFileURL else {
                    throw PluginProcessError.commandNotBound(rule.command)
                }
                guard request.arguments.count <= 128,
                      request.arguments.starts(with: rule.argumentPrefix),
                      rule.allowsAdditionalArguments || request.arguments == rule.argumentPrefix else {
                    throw PluginProcessError.argumentsDenied
                }
                guard Set(request.environment.keys).isSubset(of: Set(rule.environmentKeys)) else {
                    throw PluginProcessError.environmentDenied
                }
                var command = ProcessCommand(executable: executable, directory: mount.context.workspace)
                command.arguments = request.arguments
                command.environment = request.environment
                var budget = ProcessBudget()
                budget.outputBytes = 33_554_432
                budget.lifetimeMilliseconds = rule.lifetimeMilliseconds
                let session = try ProcessSession(command: command, budget: budget)
                let entry = ProcessEntry(session: session, generation: mount.generation, permissionID: rule.id, maximumBytes: budget.outputBytes)
                processes[session.id] = entry
                return PluginProcessUpdate(handle: session.id)
            }
            guard let handle = request.handle, let entry = processes[handle], entry.generation == mount.generation else {
                throw PluginProcessError.invalidHandle
            }
            guard mount.permissions.processes.first(where: { $0.id == entry.permissionID })?.entryPoints.contains(entryPoint) == true else {
                throw PluginProcessError.notAuthorized
            }
            switch request.operation {
            case .start: preconditionFailure("handled above")
            case .poll:
                let update = entry.poll()
                if update.exitStatus != nil || update.failure != nil { processes.removeValue(forKey: handle) }
                return update
            case .write:
                guard let data = request.input, data.count <= 8192 else { throw PluginProcessError.invalidRequest }
                try entry.session.write(data)
            case .closeInput: entry.session.closeInput()
            case .stop:
                entry.session.cancel()
                processes.removeValue(forKey: handle)
            }
            return PluginProcessUpdate(handle: handle)
        }
    }
}
