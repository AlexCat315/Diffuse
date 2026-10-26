public enum VersionControlContributionPoint: ContributionPointSpec {
    public static let id = "cove.vcs/v1"

    public static func validate(_ value: VersionControlContribution, host: PluginHostPermissions) throws {
        guard ContributionValidation.identifier(value.id), ContributionValidation.title(value.title),
              ContributionValidation.fileName(value.marker), ContributionValidation.fileName(value.ignoreFile),
              host.processes.count == 1,
              host.processes[0].entryPoints == [VersionControlContribution.entryPoint] else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }

    public static func validateRuntime(_ descriptor: VersionControlContribution, contract: WITContract?) throws {
        guard contract?.capabilityInputs.first(where: { $0.name == VersionControlContribution.entryPoint })?.inputType == stepInputType else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }
}

public enum TaskContributionPoint: ContributionPointSpec {
    public static let id = "cove.tasks/v1"

    public static func validate(_ value: TaskContribution, host: PluginHostPermissions) throws {
        guard ContributionValidation.identifier(value.id), ContributionValidation.title(value.title),
              ContributionValidation.fileName(value.marker),
              host.processes.filter({ $0.entryPoints.contains(TaskContribution.entryPoint) }).count == 1 else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }

    public static func validateRuntime(_ descriptor: TaskContribution, contract: WITContract?) throws {
        guard contract?.capabilityInputs.first(where: { $0.name == TaskContribution.entryPoint })?.inputType == stepInputType else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }
}

