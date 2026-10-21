import Foundation
import ScriptRuntime

struct ScriptAnalysisConfiguration: Sendable {
    let scriptsDirectory: URL
    let buildDirectory: URL
    let engineModulePaths: [String]
    let clangModuleMapPaths: [String]
    let clangIncludePaths: [String]

    func compiler(toolchain: SwiftToolchain?, fallback: String) -> SwiftScriptCompiler {
        SwiftScriptCompiler(swiftcPath: toolchain?.compilerURL.path ?? fallback,
                            includePaths: engineModulePaths, clangModuleMapPaths: clangModuleMapPaths,
                            clangIncludePaths: clangIncludePaths, outputDirectory: buildDirectory,
                            environment: toolchain?.environment ?? ProcessInfo.processInfo.environment)
    }

    func support(toolchain: SwiftToolchain, plugin: PluginLanguageService) -> ScriptLanguageSupport {
        ScriptLanguageSupport(scriptsDirectoryURL: scriptsDirectory, engineModulePaths: engineModulePaths,
                              clangModuleMapPaths: clangModuleMapPaths, clangIncludePaths: clangIncludePaths,
                              executableURL: toolchain.languageServerURL, environment: toolchain.environment,
                              connect: { try plugin.connect($0) }, memoryUsage: { plugin.residentMemoryBytes })
    }

    func validate(_ toolchain: SwiftToolchain) async throws {
        try await toolchain.validateAnalysis(engineModulePaths: engineModulePaths, clangModuleMapPaths: clangModuleMapPaths,
                                       clangIncludePaths: clangIncludePaths)
    }
}

final class ScriptToolchainSession: @unchecked Sendable {
    struct State {
        var toolchain: SwiftToolchain?
        var support: ScriptLanguageSupport?
        var failure: String?
    }
    private let lock = NSLock()
    private var value: State

    init(_ state: State) { value = state }
    var state: State { lock.withLock { value } }
    func replace(_ state: State) { lock.withLock { value = state } }
}
