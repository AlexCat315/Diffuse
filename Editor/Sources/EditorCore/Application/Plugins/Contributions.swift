import PluginRuntime

/// Registrations belong to the manager; each domain reads its own snapshot.
final class PluginContributions: Sendable {
    let themes = EditorThemeCatalog()
    let languages = ContributionCatalog<ValidatedPluginPackage>()
    let providers = ContributionCatalog<ValidatedPluginPackage>()
    let tasks = ContributionCatalog<ValidatedPluginPackage>()
    let versionControl = ContributionCatalog<ValidatedPluginPackage>()

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
        try registrar.register(TaskContributionPoint.self) { [tasks] values, package in
            try tasks.install(values, package: package, point: TaskContributionPoint.self, id: { $0.id })
        }
        try registrar.register(VersionControlContributionPoint.self) { [versionControl] values, package in
            try versionControl.install(values, package: package, point: VersionControlContributionPoint.self, id: { $0.id })
        }
        return registrar
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
