import Foundation

/// Appends resolved-intent records to `.guava/intent_training.jsonl` for future model fine-tuning.
///
/// Each line is a self-contained JSON object:
/// ```json
/// {"ts":"2026-05-07T12:00:00Z","locale":"zh-Hans","text":"创建一个实体","verb":"scene.spawn_entity",
///  "layer":"local","confidence":0.87,"outcome":"applied"}
/// ```
///
/// Outcome values:
/// - `"applied"` — intent was resolved and the transaction committed
/// - `"discarded"` — user rejected the confirmation dialog
/// - `"unresolved"` — no layer could produce a verb (goes to the unresolved queue)
///
/// This file is intentionally append-only and never read back at runtime.
/// Process it offline with `jq` or a small Python script for training.
public enum IntentTrainingLogger {

    public struct Entry {
        public var text: String
        public var verb: String?
        public var layer: String
        public var confidence: Double
        public var outcome: String
        public var locale: String?

        public init(text: String,
                    verb: String?,
                    layer: String,
                    confidence: Double,
                    outcome: String,
                    locale: String? = nil) {
            self.text = text
            self.verb = verb
            self.layer = layer
            self.confidence = confidence
            self.outcome = outcome
            self.locale = locale
        }
    }

    private static func makeISO8601() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    /// Appends `entry` as a JSON line to `<projectDirectory>/.guava/intent_training.jsonl`.
    /// Silently drops the record if the directory cannot be created or the write fails —
    /// logging failures must never disrupt the editor's normal flow.
    public static func log(_ entry: Entry, projectDirectory: String) {
        var obj: [String: Any] = [
            "ts": makeISO8601().string(from: Date()),
            "text": entry.text,
            "layer": entry.layer,
            "confidence": entry.confidence,
            "outcome": entry.outcome,
        ]
        if let verb = entry.verb    { obj["verb"] = verb }
        if let locale = entry.locale { obj["locale"] = locale }

        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line += "\n"

        let dir = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent(".guava", isDirectory: true)
        let file = dir.appendingPathComponent("intent_training.jsonl")

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: file.path) {
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? Data(line.utf8).write(to: file, options: .atomic)
        }
    }
}
