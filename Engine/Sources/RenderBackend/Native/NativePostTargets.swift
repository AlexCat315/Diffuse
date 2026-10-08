import NativeRHI

struct NativePostTargets {
    /// Matches the scene color/depth capacity, including history and snapshot.
    let size: RenderDrawableSize
    let a: Texture
    let b: Texture
    let history: Texture
    let snapshot: Texture
    let ldr: Texture
    var textures: [Texture] { [a,b,history,snapshot,ldr] }
    func next(after texture: Texture) -> Texture { texture == a ? b : a }
    func destroy(device: Device) { textures.forEach { device.destroy($0) } }
    static func make(device: Device, size: RenderDrawableSize) throws -> NativePostTargets {
        var textures: [Texture] = []
        do {
            for index in 0..<5 {
                textures.append(try device.makeTexture(TextureDescriptor(width: Int(size.width),height: Int(size.height),
                    format: index == 4 ? .bgra8Unorm : .rgba16Float,
                    usage: [.colorTarget,.sampled,.transferSource,.transferDestination],label: "native-post-\(index)")))
            }
            return NativePostTargets(size: size,a: textures[0],b: textures[1],history: textures[2],snapshot: textures[3],ldr: textures[4])
        } catch { textures.forEach { device.destroy($0) }; throw error }
    }
}
