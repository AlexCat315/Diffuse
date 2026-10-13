import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else { fatalError("Usage: swift install.swift <products-directory> <prefix>") }
let products = URL(fileURLWithPath: arguments[0])
let destination = URL(fileURLWithPath: arguments[1]).appendingPathComponent("bin")
let manager = FileManager.default
try manager.createDirectory(at: destination, withIntermediateDirectories: true)
for name in ["guava", "guava.exe", "GuavaTools_GuavaCLI.bundle", "GuavaTools_GuavaCLI.resources"] {
    let source = products.appendingPathComponent(name)
    guard manager.fileExists(atPath: source.path) else { continue }
    let target = destination.appendingPathComponent(name)
    if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
    try manager.copyItem(at: source, to: target)
}
print("Installed guava in \(destination.path). Add that directory to PATH.")
