import RenderBackend

public enum StylizedProbeScene {
    /// The full post graph plus toon materials, inverted-hull outlines and ink
    /// paper. Continuous camera motion exercises every opaque stylized frame.
    public static func packet(size: RenderDrawableSize, frame: Int = 0) -> RenderPacket {
        var packet = PostProbeScene.packet(size: size,frame: frame)
        packet.renderSettings.enableStylizedCharacterShading = true
        packet.scene.camera.eye.x += Float(frame % 11)*0.002
        return packet
    }
}
