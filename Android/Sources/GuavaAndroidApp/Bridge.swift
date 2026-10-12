import Foundation
import CAndroidHost

private func session(_ pointer: UnsafeMutableRawPointer) -> SurfaceSession {
    Unmanaged<SurfaceSession>.fromOpaque(pointer).takeUnretainedValue()
}

private func string(_ pointer: UnsafePointer<UInt16>?, _ count: Int32) -> String {
    guard let pointer, count > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(count)), as: UTF16.self)
}

@_cdecl("guava_android_open")
func openSurface(_ window: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32, _ scale: Float,
                 _ checkpoint: UnsafePointer<UInt16>?, _ count: Int32) -> UnsafeMutableRawPointer? {
    guard let window, width > 0, height > 0 else { return nil }
    do {
        let value = try SurfaceSession(window: window, width: Int(width), height: Int(height),
                                       scale: scale, checkpoint: string(checkpoint, count))
        return Unmanaged.passRetained(value).toOpaque()
    } catch { guava_android_log("FAIL open: \(error)"); return nil }
}

@_cdecl("guava_android_frame")
func renderFrame(_ pointer: UnsafeMutableRawPointer?) -> Int32 {
    guard let pointer else { return 0 }
    do { return try session(pointer).frame() ? 1 : 0 }
    catch { guava_android_log("FAIL frame: \(error)"); return -1 }
}

@_cdecl("guava_android_pointer")
func pointerEvent(_ pointer: UnsafeMutableRawPointer?, _ kind: Int32, _ x: Float, _ y: Float) {
    guard let pointer else { return }
    session(pointer).scene.pointer(kind: kind, x: x, y: y)
}

@_cdecl("guava_android_text")
func textEvent(_ pointer: UnsafeMutableRawPointer?, _ text: UnsafePointer<UInt16>?, _ count: Int32, _ composing: Int32) {
    guard let pointer else { return }
    session(pointer).scene.text(string(text, count), composing: composing != 0)
}

@_cdecl("guava_android_key")
func keyEvent(_ pointer: UnsafeMutableRawPointer?, _ scancode: UInt32) {
    guard let pointer else { return }
    session(pointer).scene.key(scancode)
}

@_cdecl("guava_android_snapshot")
func copySnapshot(_ pointer: UnsafeMutableRawPointer?, _ output: UnsafeMutablePointer<UInt16>?, _ capacity: Int32) -> Int32 {
    guard let pointer else { return 0 }
    let value = Array(session(pointer).scene.snapshot().utf16)
    if let output, capacity >= value.count { output.update(from: value, count: value.count) }
    return Int32(value.count)
}

@_cdecl("guava_android_close")
func closeSurface(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<SurfaceSession>.fromOpaque(pointer).release()
}
