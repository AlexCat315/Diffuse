import Foundation

struct BuildOptions {
    let configuration: String
    let signing: APKSigning?
    let install: Bool
    let serial: String?

    init(_ arguments: Arguments) throws {
        configuration = arguments.configuration.rawValue
        signing = try APKSigning.parse(arguments)
        install = arguments.operation == .run || arguments.operation == .showcase
        serial = arguments.value(.device)
    }

    func output(_ arguments: Arguments, default defaultURL: URL) throws -> URL {
        let output = arguments.url(.output) ?? defaultURL
        guard output.pathExtension.lowercased() == "apk" else { throw ToolError.invalid("--output must name an .apk file") }
        return output
    }
}

struct BuildReport: Encodable {
    let application: ApplicationIdentity
    let source: String
    let apk: String
    let configuration: String
    let signing: String
    var target = AndroidToolchain.triple
    var swiftSDK = AndroidToolchain.sdkID
    var scripts: Int? = nil
}
