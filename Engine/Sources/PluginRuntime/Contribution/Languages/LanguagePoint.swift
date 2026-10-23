import Foundation

public enum LanguageContributionPoint: ContributionPointSpec {
    public static let id = "guava.language/v1"

    public static func validate(_ language: LanguageContribution, host: PluginHostPermissions) throws {
        guard ContributionValidation.identifier(language.id), ContributionValidation.title(language.title),
              !language.extensions.isEmpty,
              Set(language.extensions).count == language.extensions.count,
              language.extensions.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_+-]{1,16}$"#, options: .regularExpression) != nil }),
              language.icon.map({ $0.range(of: #"^[a-z0-9_-]{1,32}$"#, options: .regularExpression) != nil }) ?? true,
              language.server.map({ server in host.processes.contains { $0.id == server.process } }) ?? true,
              language.grammar.map(validGrammar) ?? true,
              language.outline.map(validOutline) ?? true,
              language.format.map({ ContributionValidation.identifier($0.entryPoint) }) ?? true else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }

    public static func validateRuntime(_ language: LanguageContribution, contract: WITContract?) throws {
        if let format = language.format {
            guard contract?.capabilityInputs.first(where: { $0.name == format.entryPoint })?.inputType
                    == documentFormatInputType else {
                throw PluginManifestValidationError.invalidContribution(id)
            }
        }
        if language.server != nil && contract == nil {
            throw PluginPackageError.runtimeRequired
        }
    }

    private static func validGrammar(_ grammar: SyntaxGrammarContribution) -> Bool {
        guard !grammar.rules.isEmpty, grammar.rules.count <= 64 else { return false }
        return grammar.rules.allSatisfy { rule in
            guard !rule.pattern.isEmpty, rule.pattern.count <= 512,
                  SyntaxToken(rawValue: rule.token) != nil else { return false }
            return (try? NSRegularExpression(pattern: rule.pattern, options: [.anchorsMatchLines])) != nil
        }
    }

    private static func validOutline(_ outline: OutlineContribution) -> Bool {
        guard !outline.rules.isEmpty, outline.rules.count <= 32 else { return false }
        return outline.rules.allSatisfy { rule in
            guard !rule.pattern.isEmpty, rule.pattern.count <= 512, (1...6).contains(rule.level),
                  let expression = try? NSRegularExpression(pattern: rule.pattern, options: [.anchorsMatchLines]) else { return false }
            return expression.numberOfCaptureGroups >= 1
        }
    }
}

