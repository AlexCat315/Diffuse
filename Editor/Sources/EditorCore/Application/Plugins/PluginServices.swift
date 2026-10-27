public import Foundation
public import PluginRuntime
public import AIRuntime

extension EditorApplication {
    public func setPluginPeers(_ peers: @escaping @MainActor @Sendable () -> [EditorApplication]) {
        pluginSession.peers = peers
    }
    public func setPluginWorkspaceResolver(_ resolver: @escaping @MainActor @Sendable (String) throws -> EditorApplication) {
        pluginSession.workspaceResolver = resolver
    }

    @MainActor
    func handlePluginHostCall(owner: String, call: PluginHostServiceCall) throws -> Data {
        guard let manifest = pluginSession.manager.enabledManifests[owner],
              let permission = PluginImportPermission(rawValue: call.permission), manifest.imports.contains(permission),
              let request = try JSONSerialization.jsonObject(with: call.request) as? [String: Any],
              let operation = request["operation"] as? String else { throw EditorProjectToolError("Plugin \(owner) cannot call \(call.permission), or the service request is invalid") }
        func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]) }
        if permission == .editor, operation == "review", let path = request["package"] as? String {
            let id = try pluginSession.serviceJobs.start(owner: owner) { [weak self] in
                guard let self else { throw PluginCommandError.unavailable }
                await self.inspectPluginForManagement(at: URL(fileURLWithPath: path))
                return Data(#"{"review":"presented"}"#.utf8)
            }
            return try json(["job": id.uuidString])
        }
        if ["poll", "cancel"].contains(operation) {
            guard let text = request["job"] as? String, let id = UUID(uuidString: text) else { throw PluginCommandError.unavailable }
            if operation == "cancel" { pluginSession.serviceJobs.cancel(id: id, owner: owner); return try json(NSNull()) }
            return try pluginSession.serviceJobs.poll(id: id, owner: owner)
        }
        switch permission {
        case .editor:
            let workspace = request["workspace"] as? String ?? projectDirectory
            let target: EditorApplication
            if workspace == projectDirectory { target = self }
            else if let resolver = pluginSession.workspaceResolver { target = try resolver(workspace) }
            else { throw PluginCommandError.unavailable }
            if operation == "tools" {
                guard !target.isUntitledWorkspace else { return try json([]) }
                let names = target.store.content.profile.projectToolNames
                return try json(ProjectToolset.tools.filter { names.contains($0.name) }.map { tool in
                    var definition = tool.providerDefinition(format: .openAICompatible)
                    definition["readOnly"] = tool.readOnly
                    return definition
                })
            }
            guard operation == "start", let message = request["message"] as? [String: Any],
                  let action = message["action"] as? String,
                  ["project_tool", "get_scene", "get_selection", "find_entities", "get_ai_entity",
                   "get_context_memory", "open_capability_session", "search_capabilities", "invoke_capability",
                   "submit_capability_plan", "close_capability_session"].contains(action) else { throw PluginCommandError.unavailable }
            let data = try json(message)
            let id = try pluginSession.serviceJobs.start(owner: owner) { [weak self, weak target] in
                guard let self, let target else { throw PluginCommandError.unavailable }
                try Task.checkCancellation()
                let before = target.store.pendingConfirmationRequest?.batchID
                let result = await target.handleMCPMessage(data)
                if before == nil, let batch = target.store.pendingConfirmationRequest?.batchID {
                    self.pluginSession.serviceJobs.own(owner: owner) { [weak target] in
                        if target?.store.pendingConfirmationRequest?.batchID == batch { target?.skipPendingConfirmation() }
                    }
                }
                return result
            }
            return try json(["job": id.uuidString])
        case .service:
            if operation == "extensions" {
                guard let point = request["point"] as? String else { throw PluginCommandError.unavailable }
                let registered = pluginSession.contributions.extensionPoints.snapshot.values.contains { package in
                    ((try? package.value.manifest.contributes.decode(PluginExtensionPointContributionPoint.self)) ?? []).contains { $0.id == point }
                }
                guard registered else { return try json([]) }
                let values: [[String: Any]] = try pluginSession.contributions.extensions.snapshot.values.flatMap { entry in
                    try entry.value.manifest.contributes.decode(PluginExtensionContributionPoint.self).filter { $0.point == point }.map { value in
                        ["pluginID": entry.value.manifest.id, "id": value.id,
                         "data": try JSONSerialization.jsonObject(with: JSONEncoder().encode(value.data), options: [.fragmentsAllowed])]
                    }
                }
                return try json(values)
            }
            if operation == "resource" {
                guard let pluginID = request["pluginID"] as? String, let resourceID = request["id"] as? String,
                      pluginSession.manager.enabledManifests[pluginID] != nil,
                      let url = pluginSession.manager.packageURLs[pluginID] else { throw PluginCommandError.unavailable }
                let package = try PluginPackageLoader().load(at: url)
                guard let resource = package.manifest.resources.first(where: { $0.id == resourceID }) else { throw PluginCommandError.unavailable }
                let data = try package.resource(at: resource.path)
                guard data.count <= 256 * 1024, let text = String(data: data, encoding: .utf8) else { throw PluginCommandError.documentTooLarge }
                return try json(["text": text])
            }
            guard operation == "start", let name = request["service"] as? String else { throw PluginCommandError.unavailable }
            let providers = pluginSession.contributions.services.snapshot.values
            guard let provider = providers.first(where: { package in
                ((try? package.value.manifest.contributes.decode(PluginServiceContributionPoint.self)) ?? []).contains { $0.id == name }
            }), let descriptor = try provider.value.manifest.contributes.decode(PluginServiceContributionPoint.self).first(where: { $0.id == name }) else {
                throw PluginCommandError.unavailable
            }
            guard provider.value.manifest.id != owner else { throw EditorProjectToolError("Call your own service directly; cross-plugin calls cannot recurse into the caller.") }
            let arguments = String(decoding: try json(request["input"] ?? NSNull()), as: UTF8.self)
            let id = try pluginSession.serviceJobs.start(owner: owner) { [weak self] in
                guard let self else { throw PluginCommandError.unavailable }
                return try await self.readEntryPoint(pluginID: provider.value.manifest.id, entryPoint: descriptor.entryPoint,
                                                     event: "onService:" + name, input: ["request": arguments])
            }
            return try json(["job": id.uuidString])
        default: throw PluginCommandError.unavailable
        }
    }
}
