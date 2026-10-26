internal import Foundation
internal import ToolSupport

extension VulkanBootstrap {
  enum Bootstrap {
    static func run(_ arguments: [String]) throws {
      var destination: String?
      var index = 0
      while index < arguments.count {
        let argument = arguments[index]
        index += 1
        switch argument {
        case "-h", "--help":
          print(VulkanBootstrap.usage)
          return
        case "--destination":
          guard index < arguments.count else {
            throw ToolError.message("argument --destination: expected one argument")
          }
          destination = arguments[index]
          index += 1
        default:
          guard argument.hasPrefix("--destination=") else {
            throw ToolError.message("unrecognized arguments: \(argument)")
          }
          destination = String(argument.dropFirst("--destination=".count))
        }
      }
      try build(
        destination: destination.map(absolutePath) ?? Repository.path("Engine/vendor/vulkan-sdk"))
    }

    static var isSupportedHost: Bool {
      #if os(Windows) || os(Linux)
        true
      #else
        false
      #endif
    }

    static func build(destination: URL) throws {
      guard isSupportedHost else {
        throw ToolError.message("Vulkan is for native Windows/Linux hosts; use Metal on macOS")
      }
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw ToolError.message(
          "Destination exists; choose a new --destination to preserve the installed SDK")
      }

      let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("cove-vulkan-build-" + UUID().uuidString)
      try Fs.directory(temporary)
      defer { try? Fs.remove(temporary) }

      for (name, sha256) in VulkanBootstrap.digests {
        let archive = temporary.appendingPathComponent(name + ".tar.gz")
        let remote =
          "https://codeload.github.com/KhronosGroup/\(name)/tar.gz/refs/tags/v\(VulkanBootstrap.version)"
        guard let url = URL(string: remote) else {
          throw ToolError.message("Invalid source URL: \(remote)")
        }
        try Download.file(from: url, to: archive, sha256: sha256)
        try Archive.extract(archive, to: temporary)
      }

      let install = temporary.appendingPathComponent("install")
      let common = ["-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_INSTALL_PREFIX=\(install.path)"]
      let headersSource = temporary.appendingPathComponent(
        "Vulkan-Headers-\(VulkanBootstrap.version)")
      let headersBuild = temporary.appendingPathComponent("headers-build")
      let loaderSource = temporary.appendingPathComponent(
        "Vulkan-Loader-\(VulkanBootstrap.version)")
      let loaderBuild = temporary.appendingPathComponent("loader-build")

      try Shell.inherit(["cmake", "-S", headersSource.path, "-B", headersBuild.path] + common)
      try Shell.inherit(["cmake", "--install", headersBuild.path, "--config", "Release"])
      try Shell.inherit(
        ["cmake", "-S", loaderSource.path, "-B", loaderBuild.path] + common + [
          "-DCMAKE_PREFIX_PATH=\(install.path)", "-DBUILD_TESTS=OFF", "-DBUILD_WERROR=OFF",
        ])
      try Shell.inherit([
        "cmake", "--build", loaderBuild.path, "--config", "Release", "--parallel", "4",
      ])
      try Shell.inherit(["cmake", "--install", loaderBuild.path, "--config", "Release"])

      try Fs.copyTree(install, to: destination)
      for (name, _) in VulkanBootstrap.digests {
        let source = temporary.appendingPathComponent("\(name)-\(VulkanBootstrap.version)")
        let entries = try FileManager.default.contentsOfDirectory(
          at: source, includingPropertiesForKeys: nil)
        guard
          let license =
            entries
            .filter({ $0.lastPathComponent.hasPrefix("LICENSE") })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first
        else {
          throw ToolError.message("Missing LICENSE in \(source.path)")
        }
        try Fs.copy(license, to: destination.appendingPathComponent("\(name)-LICENSE.txt"))
      }

      print("VULKAN_SDK=\(destination.resolvingSymlinksInPath().path)")
      print("The GPU driver must provide a native Vulkan ICD.")
    }
  }
}
