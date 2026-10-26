import Testing
@testable import EditorCore

@Suite("Dynamic script toolchain")
struct DynamicScriptToolchainTests {
    @Test("host compiler override is explicit and preserves default lookup")
    func compilerSelection() {
        #expect(DynamicScriptManager.resolvedCompilerPath(environment: [:]) == "swiftc")
        #expect(DynamicScriptManager.resolvedCompilerPath(environment: [
            "COVE_SWIFTC_PATH": "/host/toolchain/swiftc"
        ]) == "/host/toolchain/swiftc")
        #expect(DynamicScriptManager.resolvedCompilerPath(override: "/explicit/swiftc", environment: [
            "COVE_SWIFTC_PATH": "/host/toolchain/swiftc"
        ]) == "/explicit/swiftc")
        #expect(DynamicScriptManager.resolvedCompilerPath(environment: [
            "COVE_SWIFTC_PATH": "  "
        ]) == "swiftc")
    }
}
