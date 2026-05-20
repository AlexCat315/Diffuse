import PackagePlugin
import Foundation

@main
struct BuildNativeDepsPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let force = arguments.contains("--force")
        let pkg = context.package.directory
        let vendorDir  = pkg.appending("vendor")
        let thirdParty = pkg.appending("third-party")
        let buildDir   = pkg.appending("build", "native")

        // SDL3.artifactbundle is the last artifact written by cmake --install,
        // so its presence reliably indicates a complete prior build.
        let sentinel = vendorDir.appending("SDL3.artifactbundle").string
        if !force && FileManager.default.fileExists(atPath: sentinel) {
            print("Engine native deps already built. Pass --force to rebuild.")
            return
        }

        guard let cmake = which("cmake") else {
            throw Fail("cmake not found on PATH — install CMake 3.20+ first.")
        }

        let src = thirdParty.string
        let bld = buildDir.string

        // Configure
        try shell(cmake, "-S", src, "-B", bld, "-DCMAKE_BUILD_TYPE=Release")
        // Build SDL3 and Jolt first; install must happen before ocio_openexr
        // because OpenEXR's cmake depends on installed Imath headers.
        try shell(cmake, "--build", bld, "--parallel", "--target", "SDL3-static")
        try shell(cmake, "--build", bld, "--parallel", "--target", "stage_jolt")
        try shell(cmake, "--install", bld)
        try shell(cmake, "--build", bld, "--parallel", "--target", "stage_ocio_openexr")
    }
}

// MARK: - Helpers

private func which(_ name: String) -> String? {
    let env = ProcessInfo.processInfo.environment
    let sep: Character = (env["OS"] == "Windows_NT") ? ";" : ":"
    let exts = (env["OS"] == "Windows_NT") ? [".exe", ".cmd", ""] : [""]
    for dir in (env["PATH"] ?? "").split(separator: sep) {
        for ext in exts {
            let path = "\(dir)/\(name)\(ext)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
    }
    return nil
}

private func shell(_ exe: String, _ args: String...) throws {
    print("$ \(([exe] + args).joined(separator: " "))")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw Fail("\(URL(fileURLWithPath: exe).lastPathComponent) exited with code \(p.terminationStatus)")
    }
}

struct Fail: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { description = msg }
}
