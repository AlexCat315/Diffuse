import PluginRuntime

/// Registrations belong to the manager; each domain reads its own snapshot.
final class PluginContributions: Sendable {
    let themes = EditorThemeCatalog()
    let languages = ContributionCatalog<ValidatedPluginPackage>()
    let providers = ContributionCatalog<ValidatedPluginPackage>()
    let agents = ContributionCatalog<ValidatedPluginPackage>()
    let tasks = ContributionCatalog<ValidatedPluginPackage>()
    let versionControl = ContributionCatalog<ValidatedPluginPackage>()
    let commands = ContributionCatalog<ValidatedPluginPackage>()
    let panels = ContributionCatalog<ValidatedPluginPackage>()
    let menus = ContributionCatalog<ValidatedPluginPackage>()
    let toolbar = ContributionCatalog<ValidatedPluginPackage>()
    let documentViews = ContributionCatalog<ValidatedPluginPackage>()
    let contexts = ContributionCatalog<ValidatedPluginPackage>()
    let harnesses = ContributionCatalog<ValidatedPluginPackage>()
    let services = ContributionCatalog<ValidatedPluginPackage>()
    let extensionPoints = ContributionCatalog<ValidatedPluginPackage>()
    let extensions = ContributionCatalog<ValidatedPluginPackage>()

    /// Every catalog the workbench reads, in a fixed order.
    var workbench: [ContributionCatalog<ValidatedPluginPackage>] { [commands, panels, menus, toolbar, documentViews] }

    func registrar() throws -> ContributionRegistrar {
        var registrar = ContributionRegistrar()
        try registrar.register(ThemeContributionPoint.self) { [themes] _, package in
            try EditorThemeCatalog.validate(package)
            return try themes.register(package)
        }
        try registrar.register(LanguageContributionPoint.self) { [languages] values, package in
            try languages.install(values, package: package, point: LanguageContributionPoint.self, id: { $0.id })
        }
        try registrar.register(AIProviderContributionPoint.self) { [providers] values, package in
            try providers.install(values, package: package, point: AIProviderContributionPoint.self, id: { $0.id })
        }
        try registrar.register(AgentContributionPoint.self) { [agents] values, package in
            try agents.install(values, package: package, point: AgentContributionPoint.self, id: { $0.id })
        }
        try registrar.register(TaskContributionPoint.self) { [tasks] values, package in
            try tasks.install(values, package: package, point: TaskContributionPoint.self, id: { $0.id })
        }
        try registrar.register(VersionControlContributionPoint.self) { [versionControl] values, package in
            try versionControl.install(values, package: package, point: VersionControlContributionPoint.self, id: { $0.id })
        }
        // The editor shows only read results; a package that writes acts
        // through the approval pipeline, not through a command or panel.
        try registrar.register(CommandContributionPoint.self) { [commands] _, package in
            guard package.manifest.access == .read else {
                throw PluginManifestValidationError.invalidContribution(CommandContributionPoint.id)
            }
            return try commands.register([package], pluginID: package.manifest.id)
        }
        try registrar.register(PanelContributionPoint.self) { [panels] values, package in
            guard values.allSatisfy({ panel in
                !EditorWorkspaceProfile.builtInPanelIDs.contains(panel.id)
                    && ContributedPanel(pluginID: package.manifest.id, contribution: panel) != nil
                    && (panel.entryPoint == nil || package.manifest.access == .read)
            }) else {
                throw PluginManifestValidationError.invalidContribution(PanelContributionPoint.id)
            }
            return try panels.install(values, package: package, point: PanelContributionPoint.self, id: { $0.id })
        }
        // Menus and the toolbar only place the package's own commands.
        try registrar.register(MenuContributionPoint.self) { [menus] values, package in
            try Self.requireOwnCommands(values.map(\.command), in: package, point: MenuContributionPoint.id)
            return try menus.register([package], pluginID: package.manifest.id)
        }
        try registrar.register(ToolbarContributionPoint.self) { [toolbar] values, package in
            try Self.requireOwnCommands(values.map(\.command), in: package, point: ToolbarContributionPoint.id)
            return try toolbar.register([package], pluginID: package.manifest.id)
        }
        try registrar.register(DocumentViewContributionPoint.self) { [documentViews] _, package in
            guard package.manifest.access == .read else {
                throw PluginManifestValidationError.invalidContribution(DocumentViewContributionPoint.id)
            }
            return try documentViews.register([package], pluginID: package.manifest.id)
        }
        // Package context goes to the model provider with the request, so only
        // read packages may supply it.
        try registrar.register(AIContextContributionPoint.self) { [contexts] values, package in
            guard package.manifest.access == .read else {
                throw PluginManifestValidationError.invalidContribution(AIContextContributionPoint.id)
            }
            return try contexts.install(values, package: package, point: AIContextContributionPoint.self, id: { $0.id })
        }
        // A harness only decides steps; it needs no write access.
        try registrar.register(AIHarnessContributionPoint.self) { [harnesses] values, package in
            guard package.manifest.access == .read else {
                throw PluginManifestValidationError.invalidContribution(AIHarnessContributionPoint.id)
            }
            return try harnesses.install(values, package: package, point: AIHarnessContributionPoint.self, id: { $0.id })
        }
        // Tools reach the model through the capability registry, which reads them
        // from the manifest; nothing else holds them.
        try registrar.register(AIToolContributionPoint.self) { _, _ in Registration {} }
        try registrar.register(PluginServiceContributionPoint.self) { [services] values, package in
            try services.install(values, package: package, point: PluginServiceContributionPoint.self, id: { $0.id })
        }
        try registrar.register(PluginExtensionPointContributionPoint.self) { [extensionPoints] values, package in
            try extensionPoints.install(values, package: package, point: PluginExtensionPointContributionPoint.self, id: { $0.id })
        }
        try registrar.register(PluginExtensionContributionPoint.self) { [extensions] _, package in
            try extensions.register([package], pluginID: package.manifest.id)
        }
        return registrar
    }

    private static func requireOwnCommands(_ names: [String], in package: ValidatedPluginPackage, point: String) throws {
        let commands = Set(((try? package.manifest.contributes.decode(CommandContributionPoint.self)) ?? []).map(\.id))
        guard names.allSatisfy(commands.contains) else { throw PluginManifestValidationError.invalidContribution(point) }
    }
}

private extension ContributionCatalog where Value == ValidatedPluginPackage {
    func install<Point: ContributionPointSpec>(_ values: [Point.Descriptor], package: ValidatedPluginPackage,
                                              point: Point.Type, id: (Point.Descriptor) -> String) throws -> Registration {
        let claimed = Set(try snapshot.values.flatMap { try $0.value.manifest.contributes.decode(point).map(id) })
        guard !values.contains(where: { claimed.contains(id($0)) }) else {
            throw PluginManifestValidationError.invalidContribution(Point.id)
        }
        return try register([package], pluginID: package.manifest.id)
    }
}
