import RenderBackend
import SceneRuntime
import SIMDCompat

public enum ParticleProbeScene {
    /// CPU-authored particles feed real GPU compaction/indirect draws on the full
    /// HDR post graph, including opaque snapshot reuse and moving particles.
    public static func packet(size: RenderDrawableSize, frame: Int = 0) -> RenderPacket {
        var packet = PostProbeScene.packet(size: size,frame: frame)
        let phase = Float(frame % 120)*0.015
        packet.scene.particles = (0..<2048).map { index -> RenderParticle in
            let x = Float(index % 64)*0.2-6.4, z = Float(index/64)*0.24-3.8
            return RenderParticle(position: SIMD3(x+sin(phase+z)*0.2,1.5+sin(x+phase)*0.9,z),size: 0.13,
                rotation: phase,color: SIMD4(0.5+Float(index % 7)*0.18,0.2+Float(index % 5)*0.1,0.8,0.55),
                alignmentAxis: index % 5 == 0 ? SIMD3(0.4,1,0) : .zero,stretch: 2,
                blendMode: (index/128)%2 == 0 ? .alpha : .additive)
        }
        for index in 0..<32 {
            packet.scene.particles.append(RenderParticle(position: SIMD3(Float(index)*0.3-4.8,3.2,3),size: 0.5,
                color: SIMD4(1.5,0.5,0.1,0.7),endColor: SIMD4(0.2,0.5,1.5,0),alignmentAxis: SIMD3(1,0.4,0),
                stretch: 2,startSize: 0.15,endSize: 0.02,shape: .ribbonSegment,blendMode: .additive))
        }
        return packet
    }
}
