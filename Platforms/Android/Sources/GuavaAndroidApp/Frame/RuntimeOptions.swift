import Foundation

/// Process-local diagnostics; these options never enter a scene checkpoint.
struct RuntimeOptions: Decodable {
    var benchmark = false
    var timings = false
    var vsync = true

    init() {}

    private enum CodingKeys: String, CodingKey { case benchmark, timings, vsync }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        benchmark = try values.decodeIfPresent(Bool.self, forKey: .benchmark) ?? benchmark
        timings = try values.decodeIfPresent(Bool.self, forKey: .timings) ?? timings
        vsync = try values.decodeIfPresent(Bool.self, forKey: .vsync) ?? vsync
    }
}
