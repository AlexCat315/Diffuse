#!/usr/bin/env swift
// Build Engine + GuavaUI native C/C++ dependencies.
// Usage: swift bootstrap.swift [--force]

import Foundation

// ── Args ──────────────────────────────────────────────────────────────────────

let force = CommandLine.arguments.dropFirst().contains("--force")

// ── Repository root ───────────────────────────────────────────────────────────

let root: URL = {
    let s = CommandLine.arguments[0]
    let raw = s.hasPrefix("/") ? URL(fileURLWithPath: s) :
              URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                  .appendingPathComponent(s)
    return raw.deletingLastPathComponent().standardized
}()

// ── Build environment ─────────────────────────────────────────────────────────

var env = ProcessInfo.processInfo.environment
env["MIMALLOC_DISABLE_REDIRECT"] = "1"

#if os(Windows)
// Activate the MSVC toolchain so cmake can find the linker and SDK headers.
if env["VCToolsInstallDir"] == nil {
    let x86 = env["ProgramFiles(x86)"] ?? "C:\\Program Files (x86)"
    let pf  = env["ProgramFiles"]       ?? "C:\\Program Files"
    var vcvars: String?

    // Locate via vswhere.exe
    let vswhere = "\(x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe"
    if FileManager.default.fileExists(atPath: vswhere),
       let path = captureExe(vswhere,
           "-latest", "-products", "*",
           "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
           "-property", "installationPath")?
           .trimmingCharacters(in: .whitespacesAndNewlines),
       !path.isEmpty {
        let c = "\(path)\\VC\\Auxiliary\\Build\\vcvarsall.bat"
        if FileManager.default.fileExists(atPath: c) { vcvars = c }
    }

    // Fallback: well-known VS 2022 edition paths
    if vcvars == nil {
        for ed in ["Community", "Professional", "Enterprise", "BuildTools"] {
            let c = "\(pf)\\Microsoft Visual Studio\\2022\\\(ed)\\VC\\Auxiliary\\Build\\vcvarsall.bat"
            if FileManager.default.fileExists(atPath: c) { vcvars = c; break }
        }
    }

    if let bat = vcvars {
        let cmd = env["ComSpec"] ?? "C:\\Windows\\System32\\cmd.exe"
        if let out = captureCmd(cmd, "\"\(bat)\" x64 >nul 2>&1 && set") {
            for line in out.components(separatedBy: "\r\n") {
                if let eq = line.firstIndex(of: "=") {
                    env[String(line[..<eq])] = String(line[line.index(after: eq)...])
                }
            }
        }
    } else {
        fputs("warning: VS 2022 C++ tools not found — cmake may fail to link.\n", stderr)
    }
}
#endif

// ── Sentinels ─────────────────────────────────────────────────────────────────

let engineDone  = root.appendingPathComponent("Engine/vendor/SDL3.artifactbundle").path
let guavaUIDone = root.appendingPathComponent("GuavaUI/vendor/yoga.artifactbundle").path

if !force
    && FileManager.default.fileExists(atPath: engineDone)
    && FileManager.default.fileExists(atPath: guavaUIDone) {
    print("Native deps already built. Run `swift bootstrap.swift --force` to rebuild.")
    exit(0)
}

// ── cmake ─────────────────────────────────────────────────────────────────────

guard let cmake = which("cmake") else {
    fputs("error: cmake not found on PATH — install CMake 3.20+ first.\n", stderr)
    exit(1)
}

// ── Engine ────────────────────────────────────────────────────────────────────

let engineSrc = root.appendingPathComponent("Engine/third-party").path
let engineBld = root.appendingPathComponent("Engine/build/native").path

// Temp prefix for cmake --install: SDL3/Jolt write to absolute vendor/ paths (unaffected),
// but FetchContent sub-projects (plutovg etc.) have system install rules that need
// redirecting away from /usr/local to avoid permission errors.
let installPrefix = FileManager.default.temporaryDirectory
    .appendingPathComponent("guava-native-install").path

print("\n── Engine ───────────────────────────────────────────────────────────")
shell(cmake, "-S", engineSrc, "-B", engineBld, "-DCMAKE_BUILD_TYPE=Release")
// Build all targets — cmake's dependency graph handles ordering:
// wgpu download → SDL3 → Jolt → image decode → Imath → OpenEXR → stage targets.
shell(cmake, "--build", engineBld, "--parallel")
// cmake --install writes SDL3/Jolt info.json to absolute vendor/ paths (unaffected by prefix).
// --prefix redirects FetchContent sub-project system install rules to a temp dir.
shell(cmake, "--install", engineBld, "--prefix", installPrefix)

// ── GuavaUI ───────────────────────────────────────────────────────────────────

let guavaSrc = root.appendingPathComponent("GuavaUI/third-party").path
let guavaBld = root.appendingPathComponent("GuavaUI/build/native").path

print("\n── GuavaUI ──────────────────────────────────────────────────────────")
shell(cmake, "-S", guavaSrc, "-B", guavaBld, "-DCMAKE_BUILD_TYPE=Release")
shell(cmake, "--build", guavaBld, "--parallel")
shell(cmake, "--install", guavaBld, "--prefix", installPrefix)

print("\nDone. Run: swift build --package-path Editor")

// ── Helpers ───────────────────────────────────────────────────────────────────

func which(_ name: String) -> String? {
    let sep: Character = env["OS"] == "Windows_NT" ? ";" : ":"
    #if os(Windows)
    let exts = ["", ".exe", ".cmd"]
    #else
    let exts = [""]
    #endif
    for dir in (env["PATH"] ?? "").split(separator: sep) {
        for ext in exts {
            let path = "\(dir)/\(name)\(ext)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
    }
    return nil
}

func shell(_ exe: String, _ args: String...) {
    print("$ \(([exe] + args).joined(separator: " "))")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.environment = env
    do { try p.run() } catch {
        fputs("error: cannot launch \(exe): \(error)\n", stderr); exit(1)
    }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        fputs("error: \(URL(fileURLWithPath: exe).lastPathComponent) exited \(p.terminationStatus)\n", stderr)
        exit(p.terminationStatus)
    }
}

func captureExe(_ exe: String, _ args: String...) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
}

#if os(Windows)
func captureCmd(_ comspec: String, _ command: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: comspec)
    p.arguments = ["/s", "/c", command]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .windowsCP1252)
}
#endif
