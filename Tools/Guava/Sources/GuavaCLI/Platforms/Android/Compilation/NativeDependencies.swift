import Foundation

struct NativeDependencies {
    struct Artifacts { let engine: URL; let text: URL }
    let toolchain: AndroidToolchain

    func prepare() throws -> Artifacts {
        let engine = toolchain.cache.appendingPathComponent("native")
        let fonts = toolchain.cache.appendingPathComponent("fonts-cmake")
        try configure(source: toolchain.root.appendingPathComponent("Engine/third-party"), directory: engine,
                      options: ["-DGUAVA_BUILD_OPENEXR=OFF"])
        try Shell.run(["cmake", "--build", engine.path, "--target", "stage_sdl3", "stage_jolt", "stage_image_decode", "stage_wasmtime",
                       "--parallel", parallelism])
        try Shell.run(["cmake", "--install", engine.path])
        try configure(source: toolchain.root.appendingPathComponent("GuavaUI/third-party"), directory: fonts, options: [])
        try Shell.run(["cmake", "--build", fonts.path, "--target", "stage_freetype", "stage_harfbuzz", "--parallel", parallelism])
        try Shell.run(["cmake", "--install", fonts.path])
        var mediaEnvironment = ProcessInfo.processInfo.environment
        mediaEnvironment["ANDROID_NDK_HOME"] = toolchain.ndk.path
        let mediaScript = toolchain.root.appendingPathComponent("Engine/Media/Native/stage.py").path
        if (try? Shell.run(["python3", mediaScript, "--platform", "android-arm64", "--check"], environment: mediaEnvironment, quiet: true)) == nil {
            try Shell.run(["python3", mediaScript, "--platform", "android-arm64"], environment: mediaEnvironment)
        }
        return Artifacts(engine: engine.appendingPathComponent("vendor"), text: fonts.appendingPathComponent("vendor"))
    }

    private var parallelism: String { ProcessInfo.processInfo.environment["CMAKE_BUILD_PARALLEL_LEVEL"] ?? "4" }

    private func configure(source: URL, directory: URL, options: [String]) throws {
        try Shell.run(["cmake", "-S", source.path, "-B", directory.path, "-G", "Ninja",
            "-DCMAKE_TOOLCHAIN_FILE=\(toolchain.ndk.path)/build/cmake/android.toolchain.cmake",
            "-DANDROID_ABI=arm64-v8a", "-DANDROID_PLATFORM=android-28", "-DANDROID_STL=c++_shared",
            "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
            "-DGUAVA_VENDOR_DIR=\(directory.path)/vendor", "-DCMAKE_INSTALL_PREFIX=\(directory.path)/install"] + options)
    }
}
