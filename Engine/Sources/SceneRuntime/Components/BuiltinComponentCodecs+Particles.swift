import Foundation
import SIMDCompat

extension BuiltinComponentCodecs {
    /// Serializes a particle emitter's configuration only — the live particle pool is
    /// transient runtime state and is not persisted.
    static func serializeParticleEmitter(_ emitter: ParticleEmitter) -> [String: Any] {
        var record: [String: Any] = [:]
        record["settings"] = encodeJSONValue(emitter.settings)
        record["moduleStack"] = encodeJSONValue(emitter.moduleStack)
        return record
    }

    static func deserializeParticleEmitter(_ record: [String: Any]) -> ParticleEmitter {
        let settings = decodeJSONValue(record["settings"], as: ParticleEmitterSettings.self) ?? .init()
        var emitter = ParticleEmitter(settings: settings)
        if let moduleStack = decodeJSONValue(record["moduleStack"], as: ParticleModuleStack.self) {
            emitter.apply(moduleStack)
        }
        return emitter
    }
}
