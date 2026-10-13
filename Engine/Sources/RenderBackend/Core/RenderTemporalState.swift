struct RenderFrameResourceVersion: Equatable {
    let meshRevision: UInt64?
    let postRevision: UInt64
    let usedSize: RenderDrawableSize
}

/// Transient history/cache state commits with a submitted frame. Authored
/// settings remain whole values; resource epochs also detect failed resizes.
struct RenderTemporalState {
    private var settings: RenderSettings?
    private var settingsGeneration: UInt64 = 0
    private var fingerprint: Int?
    private var resources: RenderFrameResourceVersion?
    private var stableFrames = 0
    var historyValid = false
    var snapshotValid = false
    private(set) var moving = true
    private(set) var cacheHit = false
    static let taaWarmupFrames = 6

    mutating func prepare(packet: RenderPacket, resources: RenderFrameResourceVersion, hdr: Bool) {
        if settings != packet.renderSettings {
            if settings?.viewport.gridEnabled != packet.renderSettings.viewport.gridEnabled { historyValid = false }
            settings = packet.renderSettings; settingsGeneration &+= 1
        }
        if !packet.renderSettings.postProcessing.taa { historyValid = false }
        let resourceChange = self.resources != resources
        if resourceChange { historyValid = false }
        let next = OpaqueSceneFingerprint.make(packet: packet,settingsGeneration: settingsGeneration)
        moving = fingerprint != next || resourceChange
        stableFrames = moving ? 0 : stableFrames + 1
        if moving { snapshotValid = false }
        cacheHit = hdr && snapshotValid && !moving
        fingerprint = next; self.resources = resources
    }
    func canCapture(settings: RenderSettings) -> Bool {
        stableFrames >= (settings.postProcessing.taa ? Self.taaWarmupFrames : 0) && (!settings.postProcessing.ssr || !moving)
    }
}
