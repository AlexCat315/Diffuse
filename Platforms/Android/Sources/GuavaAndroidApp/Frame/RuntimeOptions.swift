import GuavaLogging
import Foundation
#if canImport(GuavaUIDevToolsProtocol)
import GuavaUIDevToolsProtocol
#endif

/// Process-local diagnostics; these options never enter a scene checkpoint.
struct RuntimeOptions: Decodable {
    var benchmark = false
    var timings = false
    var vsync = true
    var logging = LogLaunch(configuration: .init(), runID: UUID().uuidString)
    var devtools: DevToolsLaunch? = nil

    init() {}

    private enum CodingKeys: String, CodingKey { case benchmark, timings, vsync, devtools, logging }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        benchmark = try values.decodeIfPresent(Bool.self, forKey: .benchmark) ?? benchmark
        timings = try values.decodeIfPresent(Bool.self, forKey: .timings) ?? timings
        vsync = try values.decodeIfPresent(Bool.self, forKey: .vsync) ?? vsync
        logging = try values.decodeIfPresent(LogLaunch.self, forKey: .logging) ?? logging
        #if DEBUG || GUAVA_PROFILE
        devtools = try values.decodeIfPresent(DevToolsLaunch.self, forKey: .devtools)
        #endif
    }
}
