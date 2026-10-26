import Foundation

public enum AIProviderContributionPoint: ContributionPointSpec {
    public static let id = "cove.ai.provider/v1"

    public static func validate(_ provider: AIProviderContribution, host: PluginHostPermissions) throws {
        guard ContributionValidation.identifier(provider.id), ContributionValidation.title(provider.title),
              ["anthropic", "openai-responses", "openai-compatible"].contains(provider.apiFormat),
              provider.baseURL.map(validURL) ?? true,
              validModels(provider.models, defaultModel: provider.defaultModel),
              provider.auth.map(validAuth) ?? true else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }

    private static func validAuth(_ auth: AIAuthContribution) -> Bool {
        auth.type == "apiKey" && !auth.fields.isEmpty && auth.fields.count <= 8
            && Set(auth.fields.map(\.id)).count == auth.fields.count
            && auth.fields.allSatisfy { field in
                ContributionValidation.identifier(field.id) && ContributionValidation.title(field.title)
                    && field.environmentVariable.map({
                        $0.range(of: #"^[A-Z][A-Z0-9_]{0,63}$"#, options: .regularExpression) != nil
                    }) ?? true
            }
    }

    private static func validModels(_ models: [AIModelContribution], defaultModel: String?) -> Bool {
        guard !models.isEmpty, models.count <= 64, Set(models.map(\.id)).count == models.count,
              defaultModel.map({ id in models.contains { $0.id == id } }) ?? true else { return false }
        return models.allSatisfy { model in
            !model.id.isEmpty && model.id.count <= 80 && ContributionValidation.title(model.title)
                && (model.contextWindow.map { $0 > 0 } ?? true)
                && (model.maxOutputTokens.map { $0 > 0 } ?? true)
        }
    }

    private static func validURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return ["https", "http"].contains(scheme) && url.host != nil && url.user == nil && url.password == nil
    }
}

