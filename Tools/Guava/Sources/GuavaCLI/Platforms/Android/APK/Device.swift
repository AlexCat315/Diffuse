import GuavaLogging
import Foundation
import GuavaUIDevToolsProtocol

enum AndroidDevice {
    static func install(_ apk: URL, toolchain: AndroidToolchain, serial: String?, identity: ApplicationIdentity, launch: DevToolsLaunch? = nil) throws -> String {
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
        let resolved = try Shell.run(command + ["shell", "cmd", "package", "resolve-activity", "--brief",
            "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", identity.id], capture: true, quiet: true)
        let activity = try launcher(resolved, applicationID: identity.id)
        var start = command + ["shell", "am", "start", "-W", "-n", activity]
        var logging = LogSystem.launch
        logging.application = identity.id
        logging.configuration.storage.directory = nil
        start += ["--es", "guava_logging", try JSONEncoder().encode(logging).base64EncodedString()]
        if let launch { start += ["--es", "guava_devtools", try JSONEncoder().encode(launch).base64EncodedString()] }
        try Shell.run(start, quiet: true)
        return device
    }
    static func launcher(_ listing: String, applicationID: String) throws -> String {
        guard let activity = listing.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { $0.hasPrefix(applicationID + "/") && !$0.contains(" ") }) else {
            throw ToolError.invalid("No launchable activity for \(applicationID); check Platforms/Android/app/src/main/AndroidManifest.xml")
        }
        return activity
    }

}
