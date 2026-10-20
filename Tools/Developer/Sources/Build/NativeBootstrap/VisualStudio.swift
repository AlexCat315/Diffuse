#if os(Windows)
  internal import Foundation
  internal import ToolSupport

  extension Bootstrap {
    /// Locates Visual Studio's `vcvarsall.bat` — first through `vswhere.exe`,
    /// then through the well-known edition paths — and imports the `x64`
    /// environment it prints so cmake can link against the MSVC toolchain.
    static func activateVisualStudio(_ environment: inout [String: String]) throws {
      guard environment["VCToolsInstallDir"] == nil else { return }

      let programsX86 = environment["ProgramFiles(x86)"] ?? "C:\\Program Files (x86)"
      let programs = environment["ProgramFiles"] ?? "C:\\Program Files"
      var vcvars: URL?

      let vswhere = URL(fileURLWithPath: programsX86)
        .appendingPathComponent("Microsoft Visual Studio/Installer/vswhere.exe")
      if FileManager.default.fileExists(atPath: vswhere.path) {
        // `vswhere` exits non-zero when no instance matches; that is not fatal.
        let output =
          (try? Shell.output(
            [
              vswhere.path, "-latest", "-products", "*",
              "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
              "-property", "installationPath",
            ],
            environment: environment)) ?? ""
        if !output.isEmpty {
          let candidate = URL(fileURLWithPath: output)
            .appendingPathComponent("VC/Auxiliary/Build/vcvarsall.bat")
          if FileManager.default.fileExists(atPath: candidate.path) { vcvars = candidate }
        }
      }

      if vcvars == nil {
        search: for edition in ["2026", "2022"] {
          for product in ["Community", "Professional", "Enterprise", "BuildTools"] {
            let candidate = URL(fileURLWithPath: programs)
              .appendingPathComponent("Microsoft Visual Studio")
              .appendingPathComponent(edition)
              .appendingPathComponent(product)
              .appendingPathComponent("VC/Auxiliary/Build/vcvarsall.bat")
            if FileManager.default.fileExists(atPath: candidate.path) {
              vcvars = candidate
              break search
            }
          }
        }
      }

      guard let vcvars else {
        Terminal.warning("Visual Studio C++ tools not found — cmake may fail to link.")
        return
      }

      let comspec = environment["ComSpec"] ?? "C:\\Windows\\System32\\cmd.exe"
      // `cmd /s /c '... && set'` dumps the environment the batch file configures.
      let dumped =
        (try? Shell.output(
          [comspec, "/s", "/c", "\"\(vcvars.path)\" x64 >nul 2>&1 && set"],
          environment: environment)) ?? ""
      for line in dumped.split(whereSeparator: \.isNewline) {
        guard let equals = line.firstIndex(of: "=") else { continue }
        environment[String(line[..<equals])] = String(line[line.index(after: equals)...])
      }
    }
  }
#endif
