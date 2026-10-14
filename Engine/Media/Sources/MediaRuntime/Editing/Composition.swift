import Foundation

/// Authored cuts. Decoder positions, GPU textures and playback clocks are transient.
public struct MediaComposition: Codable, Equatable, Sendable {
    public struct Clip: Codable, Equatable, Sendable {
        public var source: String
        public var start: Double
        public var duration: Double
        public init(source: String, start: Double = 0, duration: Double) {
            self.source = source; self.start = start; self.duration = duration
        }
        func validate() throws {
            guard !source.isEmpty, !source.hasPrefix("/"), !source.contains("\\"),
                  !source.split(separator: "/").contains(".."), !source.contains(":"),
                  start.isFinite, start >= 0, duration.isFinite, duration > 0, (start + duration).isFinite else {
                throw MediaError.invalid("Clips require a project-relative file and a finite positive range")
            }
        }
    }
    public struct Video: Codable, Equatable, Sendable {
        public var width = 1920
        public var height = 1080
        public var framesPerSecond = 30
        public init() {}
        private enum CodingKeys: CodingKey { case width, height, framesPerSecond }
        public init(from decoder: Decoder) throws {
            self.init()
            let values = try decoder.container(keyedBy: CodingKeys.self)
            width = try values.decodeIfPresent(Int.self, forKey: .width) ?? width
            height = try values.decodeIfPresent(Int.self, forKey: .height) ?? height
            framesPerSecond = try values.decodeIfPresent(Int.self, forKey: .framesPerSecond) ?? framesPerSecond
        }
        func validate() throws {
            guard (2...8192).contains(width), (2...8192).contains(height), width % 2 == 0, height % 2 == 0,
                  (1...120).contains(framesPerSecond) else { throw MediaError.invalid("Export requires even dimensions up to 8192 and 1...120 fps") }
        }
    }
    public var clips: [Clip] = []
    public var video = Video()
    public init() {}
    private enum CodingKeys: CodingKey { case clips, video }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clips = try values.decodeIfPresent([Clip].self, forKey: .clips) ?? clips
        video = try values.decodeIfPresent(Video.self, forKey: .video) ?? video
    }
    public var duration: Double { clips.reduce(0) { $0 + $1.duration } }
    public func validate() throws {
        guard !clips.isEmpty, clips.count <= 256, duration.isFinite else { throw MediaError.invalid("A composition requires 1...256 clips") }
        try video.validate()
        for clip in clips { try clip.validate() }
    }
}
