import Foundation

enum AndroidDevice {
    static func install(_ apk: URL, toolchain: AndroidToolchain, serial: String?, identity: ApplicationIdentity) throws {
        let adb = toolchain.sdk.appendingPathComponent("platform-tools/adb").path
        let listing = try Shell.run([adb, "devices"], capture: true)
        let ready = listing.split(separator: "\n").dropFirst().compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 2 && fields[1] == "device" ? String(fields[0]) : nil
        }
        guard let device = serial ?? (ready.count == 1 ? ready.first : nil), ready.contains(device) else {
            throw ToolError.invalid("Connect an authorized device; use --device when multiple devices are connected")
        }
        let command = [adb, "-s", device]
        try Shell.run(command + ["install", "--no-incremental", "-r", apk.path])
        try Shell.run(command + ["shell", "am", "force-stop", identity.id])
        try Shell.run(command + ["shell", "am", "start", "-W", "-n", identity.id + "/com.guava.probe.MainActivity"])
    }
}
