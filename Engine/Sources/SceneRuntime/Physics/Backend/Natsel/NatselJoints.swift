import SIMDCompat
internal import Natsel

extension NatselPhysicsBackend {
    func jointPositionError(_ joint: PhysicsJoint) -> Float {
        guard let a = bodies[joint.entityA], let b = bodies[joint.entityB] else { return 0 }
        let pA = world.bodyWorldPoint(a.id, nv(joint.pivotA))
        let pB = world.bodyWorldPoint(b.id, nv(joint.pivotB))
        let distance = Natsel.length(Natsel.subPos(pB, pA))
        if case .distance(let limits) = joint.configuration {
            return max(0, max(limits.minimumDistance - distance, distance - limits.maximumDistance))
        }
        return distance
    }

    func axisRotation(_ axis: SIMD3<Float>, from: SIMD3<Float>) -> Natsel.Quat {
        let length = simd_length(axis)
        let target = length > 0.000001 ? axis / length : from
        let dot = simd_dot(from, target)
        if dot < -0.99999 {
            let perpendicular = abs(from.x) < 0.9 ? simd_normalize(simd_cross(from, SIMD3<Float>(1, 0, 0)))
                : simd_normalize(simd_cross(from, SIMD3<Float>(0, 1, 0)))
            return nq(SIMD4(perpendicular, 0))
        }
        return nq(SIMD4(simd_cross(from, target), 1 + dot))
    }

    func upsertJoint(_ descriptor: PhysicsConstraintDescriptor) throws {
        if jointDescriptors[descriptor.entity] == descriptor, let id = joints[descriptor.entity], world.jointIsValid(id) { return }
        removeJoint(descriptor.entity)
        let joint = descriptor.constraint
        guard joint.isEnabled, let a = bodies[joint.entityA], let b = bodies[joint.entityB] else { return }
        guard a.id != b.id else { throw failure(.invalidArgument, "A joint needs two distinct bodies") }
        var base = Natsel.JointDef()
        base.bodyIdA = a.id
        base.bodyIdB = b.id
        base.localFrameA.p = nv(joint.pivotA)
        base.localFrameB.p = nv(joint.pivotB)
        base.localFrameA.q = axisRotation(joint.axisA, from: SIMD3(0, 0, 1))
        base.localFrameB.q = axisRotation(joint.axisB, from: SIMD3(0, 0, 1))
        let id: Natsel.JointID
        switch joint.configuration {
        case .point:
            var def = Natsel.SphericalJointDef()
            def.base = base
            id = world.createSphericalJoint(def)
        case .fixed:
            var def = Natsel.WeldJointDef()
            def.base = base
            id = world.createWeldJoint(def)
        case .distance(let value):
            var def = Natsel.DistanceJointDef()
            def.base = base
            def.enableLimit = true
            def.minLength = max(0, value.minimumDistance)
            def.maxLength = max(def.minLength, value.maximumDistance)
            let pA = world.bodyWorldPoint(a.id, nv(joint.pivotA))
            let pB = world.bodyWorldPoint(b.id, nv(joint.pivotB))
            def.length = min(def.maxLength, max(def.minLength, Natsel.length(Natsel.subPos(pB, pA))))
            def.enableSpring = value.spring.frequency > 0
            def.hertz = value.spring.frequency
            def.dampingRatio = value.spring.damping
            id = world.createDistanceJoint(def)
        case .hinge(let value):
            var def = Natsel.RevoluteJointDef()
            def.base = base
            def.enableLimit = true
            def.lowerAngle = max(-0.99 * .pi, value.minimumAngle)
            def.upperAngle = min(0.99 * .pi, max(def.lowerAngle, value.maximumAngle))
            def.enableSpring = value.spring.frequency > 0 || value.motor.mode == .position
            def.hertz = value.spring.frequency > 0 ? value.spring.frequency : 5
            def.dampingRatio = value.spring.damping
            def.targetAngle = value.motor.targetPosition
            def.enableMotor = value.motor.mode == .velocity
            def.motorSpeed = value.motor.targetVelocity
            def.maxMotorTorque = value.motor.maxForce
            id = world.createRevoluteJoint(def)
        case .slider(let value):
            base.localFrameA.q = axisRotation(value.axisA, from: SIMD3(1, 0, 0))
            base.localFrameB.q = axisRotation(value.axisB, from: SIMD3(1, 0, 0))
            var def = Natsel.PrismaticJointDef()
            def.base = base
            def.enableLimit = true
            def.lowerTranslation = value.minimumDistance
            def.upperTranslation = max(value.minimumDistance, value.maximumDistance)
            def.enableSpring = value.spring.frequency > 0 || value.motor.mode == .position
            def.hertz = value.spring.frequency > 0 ? value.spring.frequency : 5
            def.dampingRatio = value.spring.damping
            def.targetTranslation = value.motor.targetPosition
            def.enableMotor = value.motor.mode == .velocity
            def.motorSpeed = value.motor.targetVelocity
            def.maxMotorForce = value.motor.maxForce
            id = world.createPrismaticJoint(def)
        case .cone(let value):
            var def = Natsel.SphericalJointDef()
            def.base = base
            def.enableConeLimit = true
            def.coneAngle = value.halfConeAngle
            def.enableTwistLimit = true
            def.lowerTwistAngle = value.minimumTwistAngle
            def.upperTwistAngle = value.maximumTwistAngle
            def.enableSpring = value.spring.frequency > 0
            def.hertz = value.spring.frequency
            def.dampingRatio = value.spring.damping
            id = world.createSphericalJoint(def)
        case .sixDOF(let value):
            base.localFrameA.q = axisRotation(value.axisA, from: SIMD3(1, 0, 0))
            base.localFrameB.q = axisRotation(value.axisB, from: SIMD3(1, 0, 0))
            var def = Natsel.SixDOFJointDef()
            def.base = base
            for axis in 0..<6 {
                let lower = axis < 3 ? value.linearMinimum[axis] : value.angularMinimum[axis - 3]
                let upper = axis < 3 ? value.linearMaximum[axis] : value.angularMaximum[axis - 3]
                let motor = axis < 3 ? value.linearMotor : value.angularMotor
                def.axes[axis].motion = lower > upper ? .free : lower == upper ? .locked : .limited
                def.axes[axis].lowerLimit = lower
                def.axes[axis].upperLimit = upper
                def.axes[axis].limitHertz = value.spring.frequency
                def.axes[axis].limitDampingRatio = value.spring.damping
                def.axes[axis].motorMode = motor.mode == .disabled ? .off : motor.mode == .velocity ? .velocity : .position
                def.axes[axis].motorTarget = motor.mode == .velocity ? motor.targetVelocity : motor.targetPosition
                def.axes[axis].maxMotorForce = motor.maxForce
            }
            id = world.createSixDOFJoint(def)
        }
        guard world.jointIsValid(id) else { throw failure(.invalidArgument, "Could not create Natsel joint") }
        joints[descriptor.entity] = id
        jointDescriptors[descriptor.entity] = descriptor
    }
}
