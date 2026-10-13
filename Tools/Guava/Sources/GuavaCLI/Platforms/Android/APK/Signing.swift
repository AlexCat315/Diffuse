import Foundation

struct APKSigning {
    let keystore: URL
    let alias: String
    let storePasswordVariable: String
    let keyPasswordVariable: String

    static func parse(_ arguments: Arguments) throws -> Self? {
        guard let keystore = arguments.url(.keystore) else {
            if [.keyAlias, .storePassword, .keyPassword].contains(where: { arguments.value($0) != nil }) {
                throw ToolError.invalid("Signing options require --keystore")
            }
            return nil
        }
        guard FileManager.default.fileExists(atPath: keystore.path) else { throw ToolError.invalid("Keystore does not exist: \(keystore.path)") }
        let signing = Self(keystore: keystore, alias: try arguments.required(.keyAlias),
                           storePasswordVariable: arguments.value(.storePassword) ?? "GUAVA_ANDROID_STORE_PASSWORD",
                           keyPasswordVariable: arguments.value(.keyPassword) ?? "GUAVA_ANDROID_KEY_PASSWORD")
        for variable in [signing.storePasswordVariable, signing.keyPasswordVariable] {
            guard let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty else {
                throw ToolError.invalid("Set the password environment variable \(variable)")
            }
        }
        return signing
    }

    static func sign(aligned: URL, output: URL, toolchain: AndroidToolchain, signing: Self?) throws {
        let tools = toolchain.sdk.appendingPathComponent("build-tools/36.1.0")
        let key = signing?.keystore ?? toolchain.cache.appendingPathComponent("debug.keystore")
        if signing == nil, !FileManager.default.fileExists(atPath: key.path) {
            try Shell.run(["keytool", "-genkeypair", "-keystore", key.path, "-storepass", "android", "-keypass", "android",
                "-alias", "androiddebugkey", "-dname", "CN=Guava Android,O=Guava,C=CN", "-keyalg", "RSA", "-keysize", "2048", "-validity", "3650"])
        }
        let options: [String]
        if let signing {
            options = ["--ks", key.path, "--ks-key-alias", signing.alias, "--ks-pass", "env:" + signing.storePasswordVariable,
                       "--key-pass", "env:" + signing.keyPasswordVariable]
        } else { options = ["--ks", key.path, "--ks-pass", "pass:android"] }
        try Shell.run([tools.appendingPathComponent("apksigner").path, "sign"] + options + ["--out", output.path, aligned.path])
        try Shell.run([tools.appendingPathComponent("apksigner").path, "verify", output.path])
    }
}
