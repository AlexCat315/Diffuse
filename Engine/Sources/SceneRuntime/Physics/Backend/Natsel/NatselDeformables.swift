import SIMDCompat
internal import Natsel

extension NatselPhysicsBackend {
    struct CharacterRecord {
        var character: Natsel.CharacterVirtual
        var descriptor: PhysicsCharacterDescriptor
        var stance = CharacterStance.standing
    }
    struct SoftRecord {
        var id: Natsel.SoftBodyID
        var descriptor: PhysicsSoftBodyDescriptor
    }

    func synchronizeFeatures(_ context: PhysicsPrepareContext, result: inout PhysicsPrepareResult) throws {
        let activeCharacters = Set(context.activeCharacters.map(\.entity))
        for entity in characters.keys.sorted(by: entityOrder) where !activeCharacters.contains(entity) {
            characters.removeValue(forKey: entity)?.character.destroy()
        }
        for descriptor in context.activeCharacters.sorted(by: { entityOrder($0.entity, $1.entity) }) {
            if characters[descriptor.entity]?.descriptor.controller != descriptor.controller {
                characters.removeValue(forKey: descriptor.entity)?.character.destroy()
                let controller = descriptor.controller
                var def = Natsel.CharacterDef()
                let rotation = rotation(descriptor.worldTransform.matrix)
                def.position = Natsel.Pos(nv(descriptor.worldTransform.translation + rotation.act(controller.center)))
                def.radius = controller.radius
                def.height = 2 * (controller.standingHalfHeight + controller.radius)
                def.maxSlopeAngle = controller.maxSlopeDegrees * .pi / 180
                def.stepUpHeight = controller.stepHeight
                def.characterPadding = controller.skinWidth
                def.mass = controller.mass
                def.maxStrength = controller.maxStrength
                let category = UInt64(1) << min(controller.layerID, 15)
                let mask = UInt64(controller.layerMask)
                def.filter = Natsel.QueryFilter(categoryBits: category | (category << Self.softQueryLayerShift), maskBits: mask)
                def.innerBodyShape.filter = Natsel.Filter(categoryBits: category, maskBits: mask)
                guard let character = Natsel.CharacterVirtual(world: world, def) else {
                    throw failure(.invalidArgument, "Invalid character capsule")
                }
                character.rotation = nq(rotation.vector)
                characters[descriptor.entity] = CharacterRecord(character: character, descriptor: descriptor)
            } else if var record = characters[descriptor.entity] {
                if record.descriptor.worldTransform != descriptor.worldTransform {
                    record.character.rotation = nq(rotation(descriptor.worldTransform.matrix).vector)
                    record.character.setPosition(Natsel.Pos(nv(descriptor.worldTransform.translation + rotation(descriptor.worldTransform.matrix).act(descriptor.controller.center))))
                }
                record.descriptor = descriptor
                characters[descriptor.entity] = record
            }
        }
        let activeSoft = Set(context.activeSoftBodies.filter { $0.softBody.isEnabled }.map(\.entity))
        for entity in softBodies.keys.sorted(by: entityOrder) where !activeSoft.contains(entity) {
            if let old = softBodies.removeValue(forKey: entity) { world.destroySoftBody(old.id); result.removedSoftBodies += 1 }
            softQuerySurfacesDirty = true
        }
        for descriptor in context.activeSoftBodies.sorted(by: { entityOrder($0.entity, $1.entity) }) where descriptor.softBody.isEnabled {
            if let old = softBodies[descriptor.entity], old.descriptor == descriptor { continue }
            if let old = softBodies[descriptor.entity], old.descriptor.softBody == descriptor.softBody, old.descriptor.topology == descriptor.topology,
               scale(old.descriptor.worldTransform.matrix) == scale(descriptor.worldTransform.matrix) {
                world.setSoftBodyTransform(old.id, Natsel.Pos(nv(descriptor.worldTransform.translation)), nq(rotation(descriptor.worldTransform.matrix).vector))
                softBodies[descriptor.entity]?.descriptor = descriptor
            } else {
                let prepared = try softDefinition(descriptor)
                let definition = prepared.definition
                let id = world.createSoftBody(definition)
                guard world.softBodyIsValid(id) else { throw failure(.invalidShape, "Invalid deformable topology") }
                if let initial = prepared.initialPositions {
                    for (index, point) in initial.enumerated() {
                        world.setSoftBodyVertexPosition(id, Int32(index), Natsel.offsetPos(definition.position, Natsel.rotateVector(definition.rotation, point)))
                    }
                }
                if let old = softBodies.updateValue(SoftRecord(id: id, descriptor: descriptor), forKey: descriptor.entity) { world.destroySoftBody(old.id) }
            }
            result.synchronizedSoftBodies += 1
            softQuerySurfacesDirty = true
        }
        try synchronizeVehicles(context, result: &result)
    }

    func stepCharacters(_ context: PhysicsStepContext) -> [CharacterState] {
        var states: [CharacterState] = []
        for entity in characters.keys.sorted(by: entityOrder) {
            var record = characters[entity]!
            let character = record.character
            let config = record.descriptor.controller
            let command = context.characterCommands[entity] ?? CharacterCommand()
            if command.stance != record.stance {
                let halfHeight = command.stance == .standing ? config.standingHalfHeight : config.crouchingHalfHeight
                if character.setShape(radius: config.radius, height: 2 * (halfHeight + config.radius)) { record.stance = command.stance }
            }
            var velocity = character.linearVelocity
            velocity.x = command.desiredVelocity.x
            velocity.z = command.desiredVelocity.z
            if character.groundState == .onGround {
                velocity.y = max(0, command.desiredVelocity.y)
                if command.jumpRequested { velocity.y = max(0, command.jumpSpeed) }
            }
            velocity += nv(context.settings.gravity) * (Float(context.stepDeltaSeconds) * config.gravityScale)
            character.linearVelocity = velocity
            character.extendedUpdate(Float(context.stepDeltaSeconds), gravity: nv(context.settings.gravity) * config.gravityScale)
            let ground: CharacterGroundState
            switch character.groundState {
            case .onGround: ground = .onGround
            case .onSteepGround: ground = .onSteepGround
            case .notSupported: ground = .notSupported
            case .inAir: ground = .inAir
            }
            let rotation = simd_quatf(vector: SIMD4<Float>(sv(character.rotation.v), character.rotation.s))
            let position = sv(character.position) - rotation.act(config.center)
            states.append(CharacterState(entity: entity, position: position, rotation: rotation.vector,
                linearVelocity: sv(character.linearVelocity), groundState: ground, groundNormal: sv(character.groundNormal),
                groundVelocity: sv(character.groundVelocity), groundEntity: bodies.first { $0.value.id == character.groundBodyId }?.key
                    ?? softQuerySurfaces.first { $0.value.body == character.groundBodyId }?.key,
                stance: record.stance))
            // Record the writeback so the following prepare does not interpret it as a teleport.
            record.descriptor.worldTransform = WorldTransform(matrix: matrix(translation: position, rotation: rotation,
                scale: scale(record.descriptor.worldTransform.matrix)))
            characters[entity] = record
        }
        return states
    }

    func softDefinition(_ descriptor: PhysicsSoftBodyDescriptor) throws -> (definition: Natsel.SoftBodyDef, initialPositions: [Natsel.Vec3]?) {
        let config = descriptor.softBody
        guard !config.selfCollision || config.vertexRadius > 0 else {
            throw failure(.invalidArgument, "Self collision requires a positive vertex radius")
        }
        let fixed = Set(descriptor.topology.fixedVertexIndices)
        var positions: [SIMD3<Float>]
        let indices = descriptor.topology.triangleIndices
        var compliance: Float
        var shear: Float
        var bend: Float
        var bendType: ClothBendType
        var volumes: [UInt32] = []
        var volumeCompliance: Float = 0
        switch descriptor.topology {
        case .cloth(let cloth):
            positions = (0..<cloth.vertexCount).map { index in
                SIMD3((Float(index % cloth.gridSizeX) - Float(cloth.gridSizeX - 1) * 0.5) * cloth.spacing,
                    0, (Float(index / cloth.gridSizeX) - Float(cloth.gridSizeZ - 1) * 0.5) * cloth.spacing)
            }
            compliance = cloth.compliance; shear = cloth.shearCompliance; bend = cloth.bendCompliance; bendType = cloth.bendType
        case .surfaceMesh(let mesh, let geometry):
            guard let geometry else { throw failure(.invalidArgument, "Soft body requires mesh geometry") }
            positions = geometry.positions
            volumes = geometry.tetrahedronIndices
            compliance = mesh.compliance; shear = mesh.shearCompliance; bend = mesh.bendCompliance; bendType = mesh.bendType
            volumeCompliance = mesh.volumeCompliance
        case .invalid: throw failure(.invalidArgument, "Soft body requires exactly one valid topology")
        }
        guard !positions.isEmpty, indices.count % 3 == 0, volumes.count % 4 == 0,
            indices.allSatisfy({ Int($0) < positions.count }), volumes.allSatisfy({ Int($0) < positions.count }),
            positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw failure(.invalidArgument, "Invalid deformable indices or vertices")
        }
        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = positions[Int(indices[i])], b = positions[Int(indices[i + 1])], c = positions[Int(indices[i + 2])]
            guard simd_length_squared(simd_cross(b - a, c - a)) > 1.0e-16 else {
                throw failure(.invalidArgument, "Degenerate deformable triangle")
            }
        }
        for i in stride(from: 0, to: volumes.count, by: 4) {
            let a = positions[Int(volumes[i])], b = positions[Int(volumes[i + 1])]
            let c = positions[Int(volumes[i + 2])], d = positions[Int(volumes[i + 3])]
            guard abs(simd_dot(b - a, simd_cross(c - a, d - a))) > 1.0e-12 else {
                throw failure(.invalidArgument, "Degenerate deformable tetrahedron")
            }
        }
        var settings = Natsel.SoftBodySettings()
        let bodyScale = scale(descriptor.worldTransform.matrix)
        settings.vertices = positions.enumerated().map { index, position in
            Natsel.SoftBodyVertex(position: nv(position * bodyScale), invMass: fixed.contains(index) ? 0 : 1 / config.vertexMass)
        }
        for i in stride(from: 0, to: indices.count, by: 3) { settings.faces.append(Natsel.SoftBodyFace(indices[i], indices[i + 1], indices[i + 2])) }
        let attributes = Natsel.SoftBodyVertexAttributes(compliance: compliance, shearCompliance: shear, bendCompliance: bend)
        settings.createConstraints([attributes], bendType: bendType == .distance ? .distance : .dihedral)
        if bendType == .none { settings.dihedralBends.removeAll() }
        var edges: Set<UInt64> = []
        for edge in settings.edges { edges.insert((UInt64(min(edge.vertex.x, edge.vertex.y)) << 32) | UInt64(max(edge.vertex.x, edge.vertex.y))) }
        for i in stride(from: 0, to: volumes.count, by: 4) {
            let v = Array(volumes[i..<(i + 4)])
            settings.volumes.append(Natsel.SoftBodyVolume(v[0], v[1], v[2], v[3], compliance: volumeCompliance))
            for a in 0..<4 {
                for b in (a + 1)..<4 {
                    let key = (UInt64(min(v[a], v[b])) << 32) | UInt64(max(v[a], v[b]))
                    if edges.insert(key).inserted { settings.edges.append(Natsel.SoftBodyEdge(v[a], v[b], compliance: compliance)) }
                }
            }
        }
        settings.calculateRestValues()
        let initialPositions = config.selfCollision ? separateDisconnectedRestComponents(&settings) : nil
        settings.calculateRestValues()
        guard settings.validate() == nil else { throw failure(.invalidArgument, "Invalid deformable constraints") }
        var def = Natsel.SoftBodyDef(settings: settings, position: Natsel.Pos(nv(descriptor.worldTransform.translation)), rotation: nq(rotation(descriptor.worldTransform.matrix).vector))
        def.iterationCount = Int32(config.solverIterations)
        def.linearDamping = config.linearDamping
        def.maxLinearVelocity = config.maxLinearVelocity
        def.friction = config.friction
        def.restitution = config.restitution
        def.pressure = config.pressure
        def.gravityScale = config.gravityScale
        def.vertexRadius = config.vertexRadius
        def.enableSleep = settingsAllowSleep(config.allowSleep)
        def.facesDoubleSided = config.facesDoubleSided
        def.enableSelfCollision = config.selfCollision
        def.filter = Natsel.Filter(categoryBits: UInt64(1) << min(config.layerID, 15), maskBits: UInt64(config.layerMask))
        return (def, initialPositions)
    }

    /// Rest-space exclusion neighborhoods must not join disconnected pieces merely because the
    /// authored starting pose folds them together. Translate independent rest components apart,
    /// preserving their internal rest lengths, and restore the authored pose after creation.
    func separateDisconnectedRestComponents(_ settings: inout Natsel.SoftBodySettings) -> [Natsel.Vec3]? {
        var parents = Array(settings.vertices.indices)
        func root(_ value: Int) -> Int {
            var i = value
            while parents[i] != i { parents[i] = parents[parents[i]]; i = parents[i] }
            return i
        }
        for edge in settings.edges {
            let a = root(Int(edge.vertex.x)), b = root(Int(edge.vertex.y))
            if a != b { parents[max(a, b)] = min(a, b) }
        }
        let roots = settings.vertices.indices.map(root)
        let unique = Set(roots).sorted()
        guard unique.count > 1 else { return nil }
        let initial = settings.vertices.map(\.position)
        let minX = initial.map(\.x).min() ?? 0
        let maxX = initial.map(\.x).max() ?? 0
        let maxEdge = settings.edges.map(\.restLength).max() ?? 1
        let spacing = max(1, maxX - minX + 4 * maxEdge)
        let component = Dictionary(uniqueKeysWithValues: unique.enumerated().map { ($0.element, $0.offset) })
        for i in settings.vertices.indices { settings.vertices[i].position.x += Float(component[roots[i]]!) * spacing }
        return initial
    }

    func settingsAllowSleep(_ allow: Bool) -> Bool { settings.allowSleep && allow }

    func softStates() -> [SoftBodyMeshState] {
        softBodies.keys.sorted(by: entityOrder).map { entity in
            let record = softBodies[entity]!
            return SoftBodyMeshState(entity: entity, positions: world.softBodyVertexPositions(record.id).map(sv),
                triangleIndices: record.descriptor.topology.triangleIndices, isSleeping: !world.softBodyIsAwake(record.id))
        }
    }
}
