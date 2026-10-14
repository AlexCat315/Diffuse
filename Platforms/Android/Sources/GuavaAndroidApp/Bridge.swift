import GuavaLogging
import GuavaAndroidContract
import Foundation
import CAndroidHost
import GuavaUIRuntime

@MainActor
private func session(_ pointer: UnsafeMutableRawPointer) -> SurfaceSession {
    Unmanaged<SurfaceSession>.fromOpaque(pointer).takeUnretainedValue()
}

private func string(_ pointer: UnsafePointer<UInt16>?, _ count: Int32) -> String {
    guard let pointer, count > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(count)), as: UTF16.self)
}

@_cdecl("guava_android_log_java")
func writeJavaLog(_ level: Int32, _ label: UnsafePointer<UInt16>?, _ labelCount: Int32,
                  _ message: UnsafePointer<UInt16>?, _ messageCount: Int32) {
    let severity = Logger.Level.allCases.indices.contains(Int(level)) ? Logger.Level.allCases[Int(level)] : .info
    LogSystem.logger(string(label, labelCount)).log(level: severity, "\(string(message, messageCount))",
        metadata: ["origin": "java"], source: "JNI", file: "RuntimeLog.java", function: "write", line: 0)
}

@MainActor
@_cdecl("guava_android_create_application")
func createApplication(_ scale: Float, _ checkpoint: UnsafePointer<UInt16>?, _ count: Int32,
                       _ configuration: UnsafePointer<UInt16>?, _ configurationCount: Int32,
                       _ options: UnsafePointer<UInt16>?, _ optionsCount: Int32) -> UnsafeMutableRawPointer? {
    do {
        let launch = try JSONDecoder().decode(SceneLaunch.self, from: Data(string(configuration, configurationCount).utf8))
        let runtime = try JSONDecoder().decode(RuntimeOptions.self, from: Data(string(options, optionsCount).utf8))
        try LogSystem.bootstrap(application: runtime.logging.application, configuration: runtime.logging.configuration, runID: runtime.logging.runID)
        LogSystem.logger("com.guava.android.application").info("Application starting")
        let value = try AndroidApplication(scale: scale, checkpoint: string(checkpoint, count), launch: launch, runtime: runtime)
        return Unmanaged.passRetained(value).toOpaque()
    } catch { LogSystem.logger("com.guava.android.application").error("Application initialization failed", metadata: ["error": "\(error)"]); return nil }
}

@MainActor
@_cdecl("guava_android_destroy_application")
func destroyApplication(_ pointer: UnsafeMutableRawPointer?) {
    if let pointer { Unmanaged<AndroidApplication>.fromOpaque(pointer).release() }
    LogSystem.flush()
}

@MainActor
@_cdecl("guava_android_open")
func openSurface(_ application: UnsafeMutableRawPointer?, _ window: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32) -> UnsafeMutableRawPointer? {
    guard let application, let window, width > 0, height > 0 else { return nil }
    do {
        let value = try SurfaceSession(application: Unmanaged<AndroidApplication>.fromOpaque(application).takeUnretainedValue(),
                                       window: window, width: Int(width), height: Int(height))
        return Unmanaged.passRetained(value).toOpaque()
    } catch { LogSystem.logger("com.guava.android.surface").error("Surface initialization failed", metadata: ["error": "\(error)"]); return nil }
}

@MainActor
@_cdecl("guava_android_frame")
func renderFrame(_ pointer: UnsafeMutableRawPointer?, _ timestamp: UInt64) -> Int32 {
    guard let pointer else { return 0 }
    do { return try session(pointer).frame(timestamp: timestamp) ? 1 : 0 }
    catch { LogSystem.logger("com.guava.android.frame").error("Frame failed", metadata: ["error": "\(error)"]); return -1 }
}

@MainActor
@_cdecl("guava_android_pointer")
func pointerEvent(_ pointer: UnsafeMutableRawPointer?, _ kind: Int32, _ x: Float, _ y: Float) {
    guard let pointer else { return }
    session(pointer).scene.pointer(kind: kind, x: x, y: y)
}

@MainActor
@_cdecl("guava_android_text")
func textEvent(_ pointer: UnsafeMutableRawPointer?, _ text: UnsafePointer<UInt16>?, _ count: Int32, _ composing: Int32) {
    guard let pointer else { return }
    session(pointer).scene.text(string(text, count), composing: composing != 0)
}

@MainActor
@_cdecl("guava_android_key")
func keyEvent(_ pointer: UnsafeMutableRawPointer?, _ scancode: UInt32, _ modifiers: UInt16) {
    guard let pointer else { return }
    session(pointer).scene.key(scancode, modifiers: KeyModifiers(rawValue: modifiers))
}

@MainActor
@_cdecl("guava_android_scroll")
func scrollEvent(_ pointer: UnsafeMutableRawPointer?, _ x: Float, _ y: Float, _ deltaX: Float, _ deltaY: Float) {
    guard let pointer else { return }
    session(pointer).scene.scroll(x: x, y: y, deltaX: deltaX, deltaY: deltaY)
}

@MainActor
@_cdecl("guava_android_key_state")
func heldKeyEvent(_ pointer: UnsafeMutableRawPointer?, _ scancode: UInt32, _ down: Int32) {
    guard let pointer else { return }
    session(pointer).scene.game?.key(scancode, down: down != 0)
}

@MainActor
@_cdecl("guava_android_snapshot")
func copySnapshot(_ pointer: UnsafeMutableRawPointer?, _ output: UnsafeMutablePointer<UInt16>?, _ capacity: Int32) -> Int32 {
    guard let pointer else { return 0 }
    return copyText(session(pointer).scene.snapshot(), output, capacity)
}

@MainActor
@_cdecl("guava_android_input_snapshot")
func copyInputSnapshot(_ pointer: UnsafeMutableRawPointer?, _ output: UnsafeMutablePointer<UInt16>?, _ capacity: Int32) -> Int32 {
    guard let pointer else { return 0 }
    return copyText(session(pointer).scene.inputSnapshot(), output, capacity)
}

private func copyText(_ text: String, _ output: UnsafeMutablePointer<UInt16>?, _ capacity: Int32) -> Int32 {
    let value = Array(text.utf16)
    if let output, capacity >= value.count { output.update(from: value, count: value.count) }
    return Int32(value.count)
}

@MainActor
@_cdecl("guava_android_edit")
func editEvent(_ pointer: UnsafeMutableRawPointer?, _ kind: Int32, _ start: Int32, _ end: Int32) {
    guard let pointer else { return }
    session(pointer).scene.edit(kind: kind, start: Int(start), end: Int(end))
}

@MainActor
@_cdecl("guava_android_close")
func closeSurface(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    session(pointer).scene.suspend()
    Unmanaged<SurfaceSession>.fromOpaque(pointer).release()
    LogSystem.flush()
}

@MainActor
@_cdecl("guava_android_pump_diagnostics")
func pumpDiagnostics(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<AndroidApplication>.fromOpaque(pointer).takeUnretainedValue().scene.content.pumpDiagnostics()
}
