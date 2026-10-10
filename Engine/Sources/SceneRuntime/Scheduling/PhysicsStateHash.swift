extension RuntimeWorldSchedule {
    func physicsStateHash(in world: RuntimeWorld) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        @inline(__always) func combine(_ value: UInt64, into hash: inout UInt64) {
            var bytes = value.littleEndian
            withUnsafeBytes(of: &bytes) { buffer in
                for byte in buffer {
                    hash ^= UInt64(byte)
                    hash &*= 1_099_511_628_211
                }
            }
        }
        @inline(__always) func combineFloat(_ value: Float, into hash: inout UInt64) {
            combine(UInt64(value.bitPattern), into: &hash)
        }
        let entities = world.entities(with: RigidBody.self)
            .sorted { $0.rawValue < $1.rawValue }
        for entity in entities {
            guard let body = world.component(RigidBody.self, for: entity),
                  let transform = world.worldTransform(for: entity)
            else { continue }
            combine(entity.rawValue, into: &hash)
            for column in [transform.matrix.columns.0, transform.matrix.columns.1,
                           transform.matrix.columns.2, transform.matrix.columns.3] {
                combineFloat(column.x, into: &hash)
                combineFloat(column.y, into: &hash)
                combineFloat(column.z, into: &hash)
                combineFloat(column.w, into: &hash)
            }
            for value in [body.linearVelocity.x, body.linearVelocity.y, body.linearVelocity.z,
                          body.angularVelocity.x, body.angularVelocity.y, body.angularVelocity.z] {
                combineFloat(value, into: &hash)
            }
            combine(body.isSleeping ? 1 : 0, into: &hash)
        }
        let joints = world.entities(with: PhysicsJoint.self).sorted { $0.rawValue < $1.rawValue }
        for entity in joints {
            guard let joint = world.component(PhysicsJoint.self, for: entity) else { continue }
            combine(entity.rawValue, into: &hash)
            combine(joint.isEnabled ? 1 : 0, into: &hash)
        }
        let characters = (world.resource(CharacterStateFrameResource.self) ?? .empty).states
            .values.sorted { $0.entity.rawValue < $1.entity.rawValue }
        for character in characters {
            combine(character.entity.rawValue, into: &hash)
            for value in [character.position.x, character.position.y, character.position.z,
                          character.linearVelocity.x, character.linearVelocity.y, character.linearVelocity.z] {
                combineFloat(value, into: &hash)
            }
            combine(UInt64(character.groundState.rawValue), into: &hash)
        }
        let vehicles = (world.resource(VehicleStateFrameResource.self) ?? .empty).states
            .values.sorted { $0.entity.rawValue < $1.entity.rawValue }
        for vehicle in vehicles {
            combine(vehicle.entity.rawValue, into: &hash)
            combineFloat(vehicle.forwardSpeed, into: &hash)
            combineFloat(vehicle.engineRPM, into: &hash)
            combine(UInt64(bitPattern: Int64(vehicle.currentGear)), into: &hash)
            combineFloat(vehicle.clutchFriction, into: &hash)
            for wheel in vehicle.wheels {
                combine(UInt64(wheel.index), into: &hash)
                combineFloat(wheel.angularVelocity, into: &hash)
                combineFloat(wheel.rotationAngle, into: &hash)
                combineFloat(wheel.steerAngle, into: &hash)
                combineFloat(wheel.suspensionLength, into: &hash)
                combine(wheel.hasContact ? 1 : 0, into: &hash)
                combine(wheel.contactEntity?.rawValue ?? 0, into: &hash)
            }
        }
        let softBodies = (world.resource(SoftBodyStateFrameResource.self) ?? .empty).states
            .values.sorted { $0.entity.rawValue < $1.entity.rawValue }
        for softBody in softBodies {
            combine(softBody.entity.rawValue, into: &hash)
            combine(UInt64(softBody.positions.count), into: &hash)
            for position in softBody.positions {
                combineFloat(position.x, into: &hash)
                combineFloat(position.y, into: &hash)
                combineFloat(position.z, into: &hash)
            }
            combine(softBody.isSleeping ? 1 : 0, into: &hash)
        }
        let destructionSources = (world.resource(DestructionStateFrameResource.self) ?? .empty).sources
            .values.sorted { $0.sourceEntity.rawValue < $1.sourceEntity.rawValue }
        for source in destructionSources {
            combine(source.sourceEntity.rawValue, into: &hash)
            combine(source.hasFractured ? 1 : 0, into: &hash)
            combine(source.isFullyFractured ? 1 : 0, into: &hash)
            combineFloat(source.accumulatedDamage, into: &hash)
            combine(UInt64(source.brokenConnectionIDs.count), into: &hash)
            for connectionID in source.brokenConnectionIDs {
                combine(UInt64(connectionID), into: &hash)
            }
            combine(UInt64(source.releasedFragmentIDs.count), into: &hash)
            for fragmentID in source.releasedFragmentIDs {
                combine(UInt64(fragmentID), into: &hash)
            }
            combine(UInt64(source.retainedFragmentIDs.count), into: &hash)
            for fragmentID in source.retainedFragmentIDs {
                combine(UInt64(fragmentID), into: &hash)
            }
            combine(UInt64(source.activeFragmentEntities.count), into: &hash)
            for index in source.activeFragmentEntities.indices {
                combine(source.activeFragmentEntities[index].rawValue, into: &hash)
                if index < source.activeFragmentIDs.count {
                    combine(UInt64(source.activeFragmentIDs[index]), into: &hash)
                }
            }
        }
        return hash
    }
}
