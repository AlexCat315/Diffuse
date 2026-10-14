import CFFmpegBridge
import Foundation

/// Kept private to synchronous decoding or a reader actor.
final class FileDecoder: @unchecked Sendable {
    let handle: OpaquePointer
    var info: GMStreamInfo { gm_info(handle) }

    init(url: URL, video: Bool) throws {
        guard url.isFileURL else { throw MediaError.invalid("Media decoding requires a local file") }
        var error = [CChar](repeating: 0, count: 512)
        guard let handle = gm_open(url.path, video ? 1 : 0, &error, error.count) else {
            throw MediaError.decoding(String(cString: error))
        }
        self.handle = handle
    }
    deinit { gm_close(handle) }

    func seek(to seconds: Double) throws {
        guard seconds.isFinite, seconds >= 0 else { throw MediaError.invalid("Seek time must be finite and nonnegative") }
        var error = [CChar](repeating: 0, count: 512)
        guard gm_seek(handle, seconds, &error, error.count) == 0 else { throw MediaError.decoding(String(cString: error)) }
    }

    func audio() throws -> PCMBuffer? {
        var samples: UnsafePointer<Float>?
        var frames: Int32 = 0
        var error = [CChar](repeating: 0, count: 512)
        let status = gm_read_audio(handle, &samples, &frames, &error, error.count)
        guard status >= 0 else { throw MediaError.decoding(String(cString: error)) }
        guard status > 0, let samples else { return nil }
        return PCMBuffer(samples: Data(bytes: samples, count: Int(frames) * 2 * MemoryLayout<Float>.size))
    }

    func video() throws -> VideoFrame? {
        var bytes: UnsafePointer<UInt8>?
        var stride: Int32 = 0
        var time: Double = 0
        var error = [CChar](repeating: 0, count: 512)
        let status = gm_read_video(handle, &bytes, &stride, &time, &error, error.count)
        guard status >= 0 else { throw MediaError.decoding(String(cString: error)) }
        guard status > 0, let bytes else { return nil }
        let info = info
        return VideoFrame(rgba: Data(bytes: bytes, count: Int(stride) * Int(info.height)),
                          width: Int(info.width), height: Int(info.height), stride: Int(stride), time: time)
    }
}
