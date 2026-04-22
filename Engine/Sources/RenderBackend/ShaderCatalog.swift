import Foundation

enum ShaderCatalogError: Error {
    case manifestMissing
    case manifestUnreadable
    case renderProgramMissing(String)
    case computeProgramMissing(String)
    case sourceMissing(String)
    case sourceUnreadable(String)
    case unsupportedModuleLayout(String)
}

struct ShaderCatalogManifest: Codable, Sendable {
    struct RenderProgram: Codable, Sendable {
        var name: String
        var vertex: String
        var fragment: String?
    }

    struct ComputeProgram: Codable, Sendable {
        var name: String
        var compute: String
        var threadcountX: Int
        var threadcountY: Int
        var threadcountZ: Int

        enum CodingKeys: String, CodingKey {
            case name
            case compute
            case threadcountX = "threadcount_x"
            case threadcountY = "threadcount_y"
            case threadcountZ = "threadcount_z"
        }
    }

    var programs: [RenderProgram]
    var computePrograms: [ComputeProgram]

    enum CodingKeys: String, CodingKey {
        case programs
        case computePrograms = "compute_programs"
    }
}

struct ShaderCatalog: Sendable {
    private let rootURL: URL
    let manifest: ShaderCatalogManifest

    init(bundle: Bundle = .module) throws {
        let rootURL = bundle.bundleURL.appending(path: "Shaders", directoryHint: .isDirectory)
        let manifestURL = rootURL.appending(path: "manifest.json", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ShaderCatalogError.manifestMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw ShaderCatalogError.manifestUnreadable
        }
        self.rootURL = rootURL
        self.manifest = try JSONDecoder().decode(ShaderCatalogManifest.self, from: data)
    }

    func renderProgram(named name: String) throws -> ShaderCatalogManifest.RenderProgram {
        guard let program = manifest.programs.first(where: { $0.name == name }) else {
            throw ShaderCatalogError.renderProgramMissing(name)
        }
        return program
    }

    func computeProgram(named name: String) throws -> ShaderCatalogManifest.ComputeProgram {
        guard let program = manifest.computePrograms.first(where: { $0.name == name }) else {
            throw ShaderCatalogError.computeProgramMissing(name)
        }
        return program
    }

    func loadSource(at relativePath: String) throws -> String {
        let sourceURL = rootURL.appending(path: relativePath, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ShaderCatalogError.sourceMissing(relativePath)
        }
        do {
            return try String(contentsOf: sourceURL, encoding: .utf8)
        } catch {
            throw ShaderCatalogError.sourceUnreadable(relativePath)
        }
    }

    func loadWGSLRenderModule(named name: String) throws -> String {
        let program = try renderProgram(named: name)
        let fragmentPath = program.fragment ?? program.vertex
        guard program.vertex == fragmentPath,
              program.vertex.hasSuffix(".wgsl")
        else {
            throw ShaderCatalogError.unsupportedModuleLayout(name)
        }
        return try loadSource(at: program.vertex)
    }
}