import Foundation
import PluginRuntime
import PluginWasmtimeRuntime
import Testing
@testable import EditorCore

@Suite("Bundled Text Languages")
struct BundledLanguagesTests {
    @Test func latexFormatCapabilityFormatsWholeDocument() throws {
        let url = try #require(BundledPlugins.plugin(id: "studio.languages")?.package)
        let package = try PluginPackageLoader().load(at: url)
        let format = try #require(((try? package.manifest.contributes.decode(LanguageContributionPoint.self)) ?? []).first { $0.id == "latex" }?.format)
        #expect(format.entryPoint == "format")
        let runtime = try EmbeddedWasmtimeComponentRuntime()
        let output = try runtime.prepare(
            package,
            capabilityID: package.manifest.id + "." + format.entryPoint,
            input: try JSONEncoder().encode(["text": "first  \r\n\r\n\r\nsecond\t\n"]),
            querySnapshot: nil,
            limits: .secureDefault
        )
        #expect(try JSONDecoder().decode(String.self, from: output)
            == "first\n\nsecond\n")
    }

    @Test func languageGrammarAndOutlineAreDeclaredByThePackage() throws {
        let url = try #require(BundledPlugins.plugin(id: "studio.languages")?.package)
        let package = try PluginPackageLoader().load(at: url)
        let latex = try #require(((try? package.manifest.contributes.decode(LanguageContributionPoint.self)) ?? []).first { $0.id == "latex" })
        #expect(latex.grammar?.rules.isEmpty == false)
        #expect(latex.outline?.rules.isEmpty == false)
        #expect(latex.format?.entryPoint == "format")
    }
}
