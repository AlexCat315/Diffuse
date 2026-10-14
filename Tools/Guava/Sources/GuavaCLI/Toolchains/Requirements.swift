import Foundation

struct ToolchainCheck {
    let name: String
    let ready: Bool
    let remedy: String

    static func executable(_ name: String, remedy: String) -> Self {
        Self(name: name, ready: (try? Shell.executable(name)) != nil, remedy: remedy)
    }
}

enum ToolchainRequirements {
    static func inspect(_ arguments: Arguments, root: URL) -> [ToolchainCheck] {
        let common = "Install Git, CMake, Ninja and Python 3. macOS: brew install git cmake ninja python; "
            + "Ubuntu/Debian: sudo apt-get install git cmake ninja-build python3 build-essential pkg-config. "
            + "Windows: winget install Git.Git Kitware.CMake Ninja-build.Ninja Python.Python.3.13; reopen the terminal."
        #if os(Windows)
        let python = "python"
        #else
        let python = "python3"
        #endif
        let commands = ["git", "cmake", "ninja", python]
        var checks = commands.map { ToolchainCheck.executable($0, remedy: common) }
        for name in ["sh", "make"] {
            checks.append(.executable(name, remedy: "FFmpeg source builds require a POSIX shell and GNU make. macOS: install Xcode tools; Linux: install make; Windows: install MSYS2 make and add its usr/bin to PATH."))
        }
        let version = (try? Shell.run([GuavaSDK.swift, "--version"], capture: true, quiet: true)) ?? ""
        checks.append(.init(name: "Swift 6.4.1", ready: version.contains("swift-6.4.1-RELEASE"),
            remedy: "Install Swift 6.4.1 from https://www.swift.org/install/. With Swiftly: swiftly install 6.4.1; swiftly use 6.4.1. GUAVA_SWIFT_EXECUTABLE can select an existing compiler."))
        #if os(macOS)
        checks.append(.init(name: "Apple platform SDK", ready: (try? Shell.run(["xcrun", "--show-sdk-path"], capture: true, quiet: true)) != nil,
            remedy: "Run xcode-select --install, complete the Apple installer, then reopen the terminal."))
        #elseif os(Windows)
        checks.append(.executable("cl.exe", remedy: "Install Visual Studio Build Tools with Desktop development with C++ and a Windows SDK. Run Guava from its Developer PowerShell."))
        #else
        checks.append(.executable("cc", remedy: common))
        if arguments.platform == .linux {
            checks.append(.executable("glslc", remedy: "Install the Vulkan SDK from https://vulkan.lunarg.com/ and a Vulkan-capable GPU driver; export VULKAN_SDK."))
        }
        #endif
        if arguments.platform == .ios {
            for name in ["xcodebuild", "xcrun", "cargo", "rustup"] {
                checks.append(.executable(name, remedy: "Install full Xcode and Rust; rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios"))
            }
        }
        if arguments.platform == .android { checks += AndroidRequirements.inspect(arguments, root: root, version: version) }
        return checks
    }
}
