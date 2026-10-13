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

    static func development(toolchain: AndroidToolchain) throws -> Self {
        let key = toolchain.cache.appendingPathComponent("debug.keystore")
        if !FileManager.default.fileExists(atPath: key.path) {
            try Files.directory(toolchain.cache)
            try Shell.run(["keytool", "-genkeypair", "-keystore", key.path, "-storepass", "android", "-keypass", "android",
                "-alias", "androiddebugkey", "-dname", "CN=Guava Android,O=Guava,C=CN", "-keyalg", "RSA", "-keysize", "2048", "-validity", "3650"])
        }
        return Self(keystore: key, alias: "androiddebugkey", storePasswordVariable: "GUAVA_BUILD_STORE_PASSWORD",
                    keyPasswordVariable: "GUAVA_BUILD_KEY_PASSWORD")
    }
}
