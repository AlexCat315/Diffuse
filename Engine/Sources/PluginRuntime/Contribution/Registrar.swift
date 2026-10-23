/// Host adapters bind a typed declaration to a domain catalog. Plugin authors
/// neither register globals nor adopt a lifecycle protocol.
public struct ContributionRegistrar: Sendable {
    private var installers: [String: @Sendable (ValidatedPluginPackage) throws -> Registration] = [:]

    public init() {}

    public mutating func register<Point: ContributionPointSpec>(
        _ point: Point.Type,
        install: @escaping @Sendable ([Point.Descriptor], ValidatedPluginPackage) throws -> Registration
    ) throws {
        guard installers[Point.id] == nil else { throw PluginManifestValidationError.invalidContribution(Point.id) }
        installers[Point.id] = { package in try install(package.manifest.contributes.decode(point), package) }
    }

    func install(_ package: ValidatedPluginPackage) throws -> DisposalScope {
        let scope = DisposalScope()
        do {
            for id in package.manifest.contributes.pointIDs {
                guard let install = installers[id] else {
                    throw PluginManifestValidationError.invalidContribution(id)
                }
                try scope.own(try install(package))
            }
            return scope
        } catch {
            try? scope.dispose()
            throw error
        }
    }
}

