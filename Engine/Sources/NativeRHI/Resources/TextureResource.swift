/// Shared ownership of one device texture. Borrow `texture` for recording;
/// retain this resource until the recorded work has been submitted.
/// Release schedules destruction after the owning frame's GPU work retires.
public final class TextureResource {
    public let device: Device
    public let descriptor: TextureDescriptor
    public let texture: Texture

    public init(device: Device, descriptor: TextureDescriptor) throws {
        self.device = device; self.descriptor = descriptor
        texture = try device.makeTexture(descriptor)
    }

    deinit { device.destroy(texture) }
}
