/// Native context limits that only the Jolt backend reads.
public struct JoltPhysicsTuning: Sendable, Equatable, Codable {
    /// Zero lets Jolt pick its default mutex count.
    public var bodyMutexCount: Int
    public var maxBodyPairs: Int
    public var maxContactConstraints: Int
    public var tempAllocatorBytes: Int

    public init(
        bodyMutexCount: Int = 0,
        maxBodyPairs: Int = 65_536,
        maxContactConstraints: Int = 10_240,
        tempAllocatorBytes: Int = 10 * 1_024 * 1_024
    ) {
        self.bodyMutexCount = min(Int(UInt32.max), max(0, bodyMutexCount))
        self.maxBodyPairs = min(Int(UInt32.max), max(1, maxBodyPairs))
        self.maxContactConstraints = min(Int(UInt32.max), max(1, maxContactConstraints))
        self.tempAllocatorBytes = min(Int(UInt32.max), max(1_024 * 1_024, tempAllocatorBytes))
    }

    private enum CodingKeys: String, CodingKey {
        case bodyMutexCount
        case maxBodyPairs
        case maxContactConstraints
        case tempAllocatorBytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = JoltPhysicsTuning()
        self.init(
            bodyMutexCount: try values.decodeIfPresent(Int.self, forKey: .bodyMutexCount) ?? defaults.bodyMutexCount,
            maxBodyPairs: try values.decodeIfPresent(Int.self, forKey: .maxBodyPairs) ?? defaults.maxBodyPairs,
            maxContactConstraints: try values.decodeIfPresent(Int.self, forKey: .maxContactConstraints)
                ?? defaults.maxContactConstraints,
            tempAllocatorBytes: try values.decodeIfPresent(Int.self, forKey: .tempAllocatorBytes)
                ?? defaults.tempAllocatorBytes
        )
    }

    func validated() -> JoltPhysicsTuning {
        JoltPhysicsTuning(
            bodyMutexCount: bodyMutexCount,
            maxBodyPairs: maxBodyPairs,
            maxContactConstraints: maxContactConstraints,
            tempAllocatorBytes: tempAllocatorBytes
        )
    }
}
