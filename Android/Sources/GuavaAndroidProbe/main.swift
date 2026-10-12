import Foundation
import NativeRHI

print("Guava Android native Swift 6.4 probe")
do {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else { throw ProbeFailure("usage: GuavaAndroidProbe ARTIFACTS OUTPUT") }
    let output = URL(fileURLWithPath: arguments[2])
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try require(NativeRHI.platformDefaultBackends == [.vulkan], "Android must select Vulkan by default")
    let surface = SurfaceDescriptor(nativeHandle: nil)
    try require(surface.kind == .androidWindow && surface.colorFormat == .rgba8Unorm, "Android surface defaults are incorrect")
    let device = try Device.make(DeviceConfig(enableValidation: false))
    print("GPU: \(device.deviceName)")
    let context = ProbeContext(device: device, artifacts: URL(fileURLWithPath: arguments[1]), output: output)
    let checks: [(String, () throws -> String)] = [
        ("layout", context.layout),
        ("transfer", context.transfer), ("compute", context.compute),
        ("raster-1x", { try context.raster(samples: 1) }), ("raster-4x", { try context.raster(samples: 4) }),
        ("guavaui-1x", { try context.ui(samples: 1) }), ("guavaui-4x", { try context.ui(samples: 4) }),
    ]
    var results: [ProbeResult] = []
    for (name, check) in checks {
        do {
            let detail = try check()
            results.append(ProbeResult(name: name, passed: true, detail: detail))
            print("PASS \(name): \(detail)")
        } catch {
            results.append(ProbeResult(name: name, passed: false, detail: String(describing: error)))
            print("FAIL \(name): \(error)")
        }
    }
    let report = ProbeReport(device: device.deviceName, backend: String(describing: device.backendAPI), results: results)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: output.appendingPathComponent("report.json"))
    if results.contains(where: { !$0.passed }) { exit(1) }
} catch {
    print("FAIL initialization: \(error)")
    exit(1)
}
