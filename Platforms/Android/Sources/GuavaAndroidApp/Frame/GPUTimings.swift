import GuavaLogging
import Foundation
import NativeRHI
import CAndroidHost

/// Rolling GPU pass timings for one surface.
///
/// The RHI profile completes asynchronously, after the GPU retires a frame, so
/// these numbers describe recently finished work rather than the frame being
/// recorded. Reported once a second so steady state produces one line per
/// second instead of one line per frame.
struct GPUTimingReporter {
    private struct Accumulator {
        var count = 0
        var total: UInt64 = 0
        var worst: UInt64 = 0
    }

    private let profile: GPUTimestampProfile?
    private var reported = 0
    private var window: [String: Accumulator] = [:]
    private var windowStart: UInt64 = 0

    /// Attaches a profile when the backend can timestamp and the caller asked
    /// for timings. Otherwise the reporter stays inactive and does no work.
    init(device: Device, enabled: Bool) {
        guard enabled, device.supportsGPUTimestamps else {
            profile = nil
            return
        }
        // Headroom for a long run: this reporter only needs the retention bound
        // not to truncate a session before its summary lines are read.
        let created = GPUTimestampProfile(markerLimit: 1 << 16)
        device.setGPUTimestampProfile(created)
        profile = created
    }

    var isRecording: Bool { profile != nil }

    mutating func tick(timestamp: UInt64) {
        guard let profile else { return }
        if windowStart == 0 { windowStart = timestamp }
        let markers = profile.recordedMarkers
        if markers.count > reported {
            for marker in markers[reported...] {
                var entry = window[marker.label] ?? Accumulator()
                entry.count += 1
                entry.total += marker.nanoseconds
                entry.worst = max(entry.worst, marker.nanoseconds)
                window[marker.label] = entry
            }
            reported = markers.count
        }
        // The heartbeat is unconditional: a window with no passes distinguishes
        // "nothing was sampled" from "sampling is not running at all".
        guard timestamp - windowStart >= 1_000_000_000 else { return }
        let windowMilliseconds = Double(timestamp - windowStart) / 1_000_000
        windowStart = timestamp
        guard !window.isEmpty else {
            LogSystem.logger("com.guava.android.timing").info("[timing] android.gpu window=\(Self.text(windowMilliseconds))ms passes=0 status=\(profile.status)")
            return
        }
        let summary = window.keys.sorted().compactMap { label -> String? in
            guard let entry = window[label], entry.count > 0 else { return nil }
            let average = Double(entry.total) / Double(entry.count) / 1_000_000
            let worst = Double(entry.worst) / 1_000_000
            // `key=value` pairs with word characters only, so the repository's
            // telemetry parser can read this line like the other timing lines.
            let key = Self.parseable(label)
            return "\(key)_avg=\(Self.text(average))ms \(key)_max=\(Self.text(worst))ms"
        }.joined(separator: " ")
        LogSystem.logger("com.guava.android.timing").info("[timing] android.gpu window=\(Self.text(windowMilliseconds))ms passes=\(window.count) \(summary)")
        window.removeAll(keepingCapacity: true)
    }

    /// Pass labels are authored for humans (`ui-segment`, `backdrop-blur-h`);
    /// telemetry keys may only use word characters.
    private static func parseable(_ label: String) -> String {
        String(label.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }

    private static func text(_ milliseconds: Double) -> String {
        String(format: "%.3f", milliseconds)
    }
}
