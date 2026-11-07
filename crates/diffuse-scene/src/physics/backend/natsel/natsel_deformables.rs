//! Character and soft-body synchronization plus their per-step state.
//!
//! Ported from `Engine/Sources/SceneRuntime/Physics/Backend/Natsel/NatselDeformables.swift`.
//!
//! The character records are the one place the backend needs a raw world pointer:
//! `CharacterVirtual<'w>` borrows `&'w mut World` for its whole life, so a backend that
//! owns the world *and* stores characters is self-referential. See the module docs on
//! `natsel_physics_backend` and `.migration/cove-gaps.md` G8. The `unsafe` blocks here
//! are the second of the two approved by the migration lead, and they are the last.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{Float3, simd_cross, simd_dot, simd_length_squared};

use natsel::character::character_virtual::{CharacterDef, CharacterVirtual};

use crate::entity_id::EntityID;
use crate::physics::backend::physics_backend_context::{
    PhysicsPrepareContext, PhysicsPrepareResult, PhysicsStepContext,
};
use crate::physics::backend::physics_descriptors::PhysicsSoftBodyDescriptor;
use crate::physics::character_controller::{
    CharacterCommand, CharacterGroundState, CharacterStance, CharacterState,
};
use crate::physics::physics_types::{PhysicsBackendError, PhysicsBackendErrorCode};
use crate::physics::soft_bodies::soft_body::SoftBodyMeshState;
use crate::physics::vehicles::vehicle_state::VehicleState;

use super::natsel_physics_backend::{CharacterRecord, NatselPhysicsBackend, SoftRecord};
use super::natsel_soft_surfaces::SOFT_QUERY_LAYER_SHIFT;

impl NatselPhysicsBackend {
    /// `synchronizeFeatures(_:result:)` — characters, soft bodies, then vehicles.
    pub(crate) fn synchronize_features(
        &mut self,
        context: &PhysicsPrepareContext,
        result: &mut PhysicsPrepareResult,
    ) -> Result<(), PhysicsBackendError> {
        self.synchronize_characters(context)?;
        self.synchronize_soft_bodies(context, result)?;
        self.synchronize_vehicles(context, result)
    }

    /// `synchronizeFeatures`'s character half. A changed controller replaces the
    /// character outright; a changed transform only teleports the existing one.
    fn synchronize_characters(
        &mut self,
        context: &PhysicsPrepareContext,
    ) -> Result<(), PhysicsBackendError> {
        let active: std::collections::BTreeSet<EntityID> = context
            .active_characters
            .iter()
            .map(|descriptor| descriptor.entity)
            .collect();
        let mut stale: Vec<EntityID> = self
            .characters
            .keys()
            .copied()
            .filter(|entity| !active.contains(entity))
            .collect();
        stale.sort_by_key(|entity| entity.raw_value());
        for entity in stale {
            if let Some(mut record) = self.characters.remove(&entity) {
                // Dropping the record destroys its inner body through the world pointer
                // Natsel holds, so no separate cleanup is needed.
                record.character.destroy();
            }
        }

        let mut descriptors = context.active_characters.clone();
        descriptors.sort_by_key(|descriptor| descriptor.entity.raw_value());
        for descriptor in descriptors {
            let controller = descriptor.controller.clone();
            let unchanged = self
                .characters
                .get(&descriptor.entity)
                .is_some_and(|record| record.descriptor.controller == controller);
            if !unchanged {
                if let Some(mut record) = self.characters.remove(&descriptor.entity) {
                    record.character.destroy();
                }
                let rotation = NatselPhysicsBackend::rotation(descriptor.world_transform.matrix);
                let center = rotation.act(controller.center);
                let category = 1u64 << controller.layer_id.min(15);
                let mask = u64::from(controller.layer_mask);
                let inner_body_shape = natsel::types::shape_def::ShapeDef {
                    filter: natsel::types::shape_def::Filter::new(category, mask, 0),
                    ..natsel::types::shape_def::ShapeDef::default()
                };
                let def = CharacterDef {
                    position: NatselPhysicsBackend::np(Float3::new(
                        descriptor.world_transform.translation().x + center.x,
                        descriptor.world_transform.translation().y + center.y,
                        descriptor.world_transform.translation().z + center.z,
                    )),
                    radius: controller.radius,
                    // Height spans both half-heights plus both radii.
                    height: 2.0 * (controller.standing_half_height + controller.radius),
                    max_slope_angle: controller.max_slope_degrees * std::f32::consts::PI / 180.0,
                    step_up_height: controller.step_height,
                    character_padding: controller.skin_width,
                    mass: controller.mass,
                    max_strength: controller.max_strength,
                    filter: natsel::types::shape_def::QueryFilter::new(
                        category | (category << SOFT_QUERY_LAYER_SHIFT),
                        mask,
                    ),
                    inner_body_shape,
                    ..CharacterDef::default()
                };
                let pointer = self.world_pointer();
                // SAFETY: the three obligations `from_raw_world` documents hold here —
                // `pointer` addresses the boxed world, which lives until `reset` and is
                // replaced only after every record is destroyed; records are touched
                // only from `prepare`/`step`/`reset`, each holding `&mut self`, so no
                // conflicting borrow exists. Multiple characters use the same world
                // sequentially, with world references scoped to each character call.
                let character = unsafe { CharacterVirtual::from_raw_world(pointer, &def) };
                let Some(mut character) = character else {
                    return Err(NatselPhysicsBackend::failure(
                        PhysicsBackendErrorCode::InvalidArgument,
                        "Invalid character capsule",
                    ));
                };
                character.rotation = NatselPhysicsBackend::nq(rotation.vector);
                self.characters.insert(
                    descriptor.entity,
                    CharacterRecord {
                        character,
                        descriptor,
                        stance: CharacterStance::Standing,
                    },
                );
            } else if let Some(record) = self.characters.get_mut(&descriptor.entity) {
                // Swift teleports an unchanged controller whose authored transform
                // moved. `stepCharacters` writes its simulated transform back into
                // the descriptor, so a mere simulation step must not re-teleport.
                if record.descriptor.world_transform != descriptor.world_transform {
                    let rotation =
                        NatselPhysicsBackend::rotation(descriptor.world_transform.matrix);
                    record.character.rotation = NatselPhysicsBackend::nq(rotation.vector);
                    let center = rotation.act(controller.center);
                    record
                        .character
                        .set_position(NatselPhysicsBackend::np(Float3::new(
                            descriptor.world_transform.translation().x + center.x,
                            descriptor.world_transform.translation().y + center.y,
                            descriptor.world_transform.translation().z + center.z,
                        )));
                }
                record.descriptor = descriptor;
            }
        }
        Ok(())
    }

    /// `synchronizeFeatures`'s soft-body half. An unchanged body whose vertices and
    /// scale match only moves; anything else is rebuilt.
    fn synchronize_soft_bodies(
        &mut self,
        context: &PhysicsPrepareContext,
        result: &mut PhysicsPrepareResult,
    ) -> Result<(), PhysicsBackendError> {
        let active: std::collections::BTreeSet<EntityID> = context
            .active_soft_bodies
            .iter()
            .filter(|descriptor| descriptor.soft_body.is_enabled)
            .map(|descriptor| descriptor.entity)
            .collect();
        let mut stale: Vec<EntityID> = self
            .soft_bodies
            .keys()
            .copied()
            .filter(|entity| !active.contains(entity))
            .collect();
        stale.sort_by_key(|entity| entity.raw_value());
        for entity in stale {
            if let Some(record) = self.soft_bodies.remove(&entity) {
                self.world.destroy_soft_body(record.id);
                result.removed_soft_bodies += 1;
            }
            self.soft_query_surfaces_dirty = true;
        }

        let mut descriptors = context.active_soft_bodies.clone();
        descriptors.sort_by_key(|descriptor| descriptor.entity.raw_value());
        for descriptor in descriptors {
            if !descriptor.soft_body.is_enabled {
                continue;
            }
            if let Some(old) = self.soft_bodies.get(&descriptor.entity) {
                if old.descriptor == descriptor {
                    continue;
                }
                let transform_only = old.descriptor.soft_body == descriptor.soft_body
                    && old.descriptor.topology == descriptor.topology
                    && NatselPhysicsBackend::scale(old.descriptor.world_transform.matrix)
                        == NatselPhysicsBackend::scale(descriptor.world_transform.matrix);
                if transform_only {
                    let id = old.id;
                    self.world.set_soft_body_transform(
                        id,
                        NatselPhysicsBackend::np(descriptor.world_transform.translation()),
                        NatselPhysicsBackend::nq(
                            NatselPhysicsBackend::rotation(descriptor.world_transform.matrix)
                                .vector,
                        ),
                    );
                    if let Some(record) = self.soft_bodies.get_mut(&descriptor.entity) {
                        record.descriptor = descriptor;
                    }
                    result.synchronized_soft_bodies += 1;
                    self.soft_query_surfaces_dirty = true;
                    continue;
                }
            }
            let prepared = self.soft_definition(&descriptor)?;
            let initial = prepared.initial_positions.clone();
            let rotation = NatselPhysicsBackend::nq(
                NatselPhysicsBackend::rotation(descriptor.world_transform.matrix).vector,
            );
            let id = self.world.create_soft_body(&prepared.definition);
            if !self.world.soft_body_is_valid(id) {
                return Err(NatselPhysicsBackend::failure(
                    PhysicsBackendErrorCode::InvalidShape,
                    "Invalid deformable topology",
                ));
            }
            if let Some(initial) = initial {
                for (index, point) in initial.iter().enumerate() {
                    self.world.set_soft_body_vertex_position(
                        id,
                        index as i32,
                        natsel::math::functions::offset_pos(
                            prepared.definition.position,
                            natsel::math::functions::rotate_vector(rotation, *point),
                        ),
                    );
                }
            }
            if let Some(old) = self
                .soft_bodies
                .insert(descriptor.entity, SoftRecord { id, descriptor })
            {
                self.world.destroy_soft_body(old.id);
            }
            result.synchronized_soft_bodies += 1;
            self.soft_query_surfaces_dirty = true;
        }
        Ok(())
    }

    /// `softDefinition(_:)` — validate the authored topology, build the constraint
    /// graph, then describe the body. Every rejection here is a real authoring error,
    /// so it returns the same messages Swift does.
    pub(crate) fn soft_definition(
        &mut self,
        descriptor: &PhysicsSoftBodyDescriptor,
    ) -> Result<SoftDefinition, PhysicsBackendError> {
        use crate::physics::backend::physics_descriptors::PhysicsSoftBodyTopology;
        use natsel::soft_body::soft_body_settings::{
            SoftBodyBendType, SoftBodyFace, SoftBodySettings, SoftBodyVertex,
            SoftBodyVertexAttributes, SoftBodyVolume,
        };

        let config = &descriptor.soft_body;
        // `!(x > 0)` rather than `x <= 0`: Swift's predicate is false for NaN, so a NaN
        // radius must *not* count as "positive" but must also not be flipped into a
        // rejection of valid configs. Written to preserve that exactly.
        #[allow(clippy::neg_cmp_op_on_partial_ord)]
        let positive_radius = config.vertex_radius > 0.0;
        if config.self_collision && !positive_radius {
            return Err(NatselPhysicsBackend::failure(
                PhysicsBackendErrorCode::InvalidArgument,
                "Self collision requires a positive vertex radius",
            ));
        }

        let fixed: std::collections::BTreeSet<i64> = descriptor
            .topology
            .fixed_vertex_indices()
            .into_iter()
            .collect();
        let indices = descriptor.topology.triangle_indices();

        let positions: Vec<Float3>;
        let compliance: f32;
        let shear: f32;
        let bend: f32;
        let bend_type: crate::physics::soft_bodies::cloth::ClothBendType;
        let mut volumes: Vec<u32> = Vec::new();
        let mut volume_compliance: f32 = 0.0;

        match &descriptor.topology {
            PhysicsSoftBodyTopology::Cloth(cloth) => {
                positions = (0..cloth.vertex_count())
                    .map(|index| {
                        Float3::new(
                            (index as f32 % cloth.grid_size_x as f32
                                - (cloth.grid_size_x as f32 - 1.0) * 0.5)
                                * cloth.spacing,
                            0.0,
                            ((index / cloth.grid_size_x) as f32
                                - (cloth.grid_size_z as f32 - 1.0) * 0.5)
                                * cloth.spacing,
                        )
                    })
                    .collect();
                compliance = cloth.compliance;
                shear = cloth.shear_compliance;
                bend = cloth.bend_compliance;
                bend_type = cloth.bend_type;
            }
            PhysicsSoftBodyTopology::SurfaceMesh(mesh, geometry) => {
                let Some(geometry) = geometry else {
                    return Err(NatselPhysicsBackend::failure(
                        PhysicsBackendErrorCode::InvalidArgument,
                        "Soft body requires mesh geometry",
                    ));
                };
                positions = geometry.positions.clone();
                volumes = geometry.tetrahedron_indices.clone();
                compliance = mesh.compliance;
                shear = mesh.shear_compliance;
                bend = mesh.bend_compliance;
                bend_type = mesh.bend_type;
                volume_compliance = mesh.volume_compliance;
            }
            PhysicsSoftBodyTopology::Invalid => {
                return Err(NatselPhysicsBackend::failure(
                    PhysicsBackendErrorCode::InvalidArgument,
                    "Soft body requires exactly one valid topology",
                ));
            }
        }

        let vertex_count = positions.len();
        let indices_valid = indices.len().is_multiple_of(3)
            && volumes.len().is_multiple_of(4)
            && indices.iter().all(|index| (*index as usize) < vertex_count)
            && volumes.iter().all(|index| (*index as usize) < vertex_count)
            && positions.iter().all(|position| {
                position.x.is_finite() && position.y.is_finite() && position.z.is_finite()
            });
        if positions.is_empty() || !indices_valid {
            return Err(NatselPhysicsBackend::failure(
                PhysicsBackendErrorCode::InvalidArgument,
                "Invalid deformable indices or vertices",
            ));
        }

        // Degenerate triangles would produce infinite constraint gradients.
        for triangle in indices.as_chunks::<3>().0 {
            let a = positions[triangle[0] as usize];
            let b = positions[triangle[1] as usize];
            let c = positions[triangle[2] as usize];
            let cross = simd_cross(b - a, c - a);
            // NaN-safe: a NaN area is not "greater than epsilon", so it is rejected.
            #[allow(clippy::neg_cmp_op_on_partial_ord)]
            let non_degenerate = simd_length_squared(cross) > 1.0e-16;
            if !non_degenerate {
                return Err(NatselPhysicsBackend::failure(
                    PhysicsBackendErrorCode::InvalidArgument,
                    "Degenerate deformable triangle",
                ));
            }
        }
        // So would degenerate tetrahedra.
        for tetrahedron in volumes.as_chunks::<4>().0 {
            let a = positions[tetrahedron[0] as usize];
            let b = positions[tetrahedron[1] as usize];
            let c = positions[tetrahedron[2] as usize];
            let d = positions[tetrahedron[3] as usize];
            // NaN-safe, as above.
            #[allow(clippy::neg_cmp_op_on_partial_ord)]
            let non_degenerate = simd_dot(b - a, simd_cross(c - a, d - a)).abs() > 1.0e-12;
            if !non_degenerate {
                return Err(NatselPhysicsBackend::failure(
                    PhysicsBackendErrorCode::InvalidArgument,
                    "Degenerate deformable tetrahedron",
                ));
            }
        }

        let body_scale = NatselPhysicsBackend::scale(descriptor.world_transform.matrix);
        let mut settings = SoftBodySettings::new();
        settings.vertices = positions
            .iter()
            .enumerate()
            .map(|(index, position)| {
                SoftBodyVertex::new(
                    NatselPhysicsBackend::nv(Float3::new(
                        position.x * body_scale.x,
                        position.y * body_scale.y,
                        position.z * body_scale.z,
                    )),
                    natsel::math::types::Vec3::ZERO,
                    if fixed.contains(&(index as i64)) {
                        0.0
                    } else {
                        1.0 / config.vertex_mass
                    },
                )
            })
            .collect();
        for triangle in indices.as_chunks::<3>().0 {
            settings
                .faces
                .push(SoftBodyFace::new(triangle[0], triangle[1], triangle[2]));
        }
        let attributes = SoftBodyVertexAttributes::new(
            compliance,
            shear,
            bend,
            natsel::soft_body::soft_body_settings::SoftBodyLRAType::None,
            0.0,
        );
        // Swift passes no tolerance; Natsel requires one, and 0.0 keeps every crease.
        settings.create_constraints(
            &[attributes],
            match bend_type {
                crate::physics::soft_bodies::cloth::ClothBendType::Distance => {
                    SoftBodyBendType::Distance
                }
                _ => SoftBodyBendType::Dihedral,
            },
            0.0,
        );
        if bend_type == crate::physics::soft_bodies::cloth::ClothBendType::None {
            settings.dihedral_bends.clear();
        }

        // Tetrahedra contribute volume constraints and any edges the faces missed.
        let mut edges: std::collections::BTreeSet<u64> = settings
            .edges
            .iter()
            .map(|edge| {
                (u64::from(edge.vertex.x.min(edge.vertex.y)) << 32)
                    | u64::from(edge.vertex.x.max(edge.vertex.y))
            })
            .collect();
        for tetrahedron in volumes.as_chunks::<4>().0 {
            let v = [
                tetrahedron[0],
                tetrahedron[1],
                tetrahedron[2],
                tetrahedron[3],
            ];
            settings.volumes.push(SoftBodyVolume::new(
                v[0],
                v[1],
                v[2],
                v[3],
                volume_compliance,
            ));
            for a in 0..4 {
                for b in (a + 1)..4 {
                    let key = (u64::from(v[a].min(v[b])) << 32) | u64::from(v[a].max(v[b]));
                    if edges.insert(key) {
                        settings.edges.push(
                            natsel::soft_body::soft_body_settings::SoftBodyEdge::new(
                                v[a], v[b], compliance,
                            ),
                        );
                    }
                }
            }
        }

        settings.calculate_rest_values();
        let initial_positions = if config.self_collision {
            self.separate_disconnected_rest_components(&mut settings)
        } else {
            None
        };
        // Rest lengths changed when components moved, so recompute them.
        settings.calculate_rest_values();
        if let Some(reason) = settings.validate() {
            let _ = reason;
            return Err(NatselPhysicsBackend::failure(
                PhysicsBackendErrorCode::InvalidArgument,
                "Invalid deformable constraints",
            ));
        }

        let mut def = natsel::soft_body::soft_body_runtime::SoftBodyDef {
            settings,
            position: NatselPhysicsBackend::np(descriptor.world_transform.translation()),
            rotation: NatselPhysicsBackend::nq(
                NatselPhysicsBackend::rotation(descriptor.world_transform.matrix).vector,
            ),
            ..Default::default()
        };
        def.iteration_count = config.solver_iterations as i32;
        def.linear_damping = config.linear_damping;
        def.max_linear_velocity = config.max_linear_velocity;
        def.friction = config.friction;
        def.restitution = config.restitution;
        def.pressure = config.pressure;
        def.gravity_scale = config.gravity_scale;
        def.vertex_radius = config.vertex_radius;
        // Authored sleep and the world setting must both allow sleeping.
        def.enable_sleep = self.settings.allow_sleep && config.allow_sleep;
        def.faces_double_sided = config.faces_double_sided;
        def.enable_self_collision = config.self_collision;
        def.filter = natsel::types::shape_def::Filter::new(
            1u64 << config.layer_id.min(15),
            u64::from(config.layer_mask),
            0,
        );
        Ok(SoftDefinition {
            definition: def,
            initial_positions,
        })
    }

    /// Rest-space exclusion neighbourhoods must not join disconnected pieces merely
    /// because the authored starting pose folds them together. Translate independent
    /// rest components apart along X, preserving their internal rest lengths.
    fn separate_disconnected_rest_components(
        &self,
        settings: &mut natsel::soft_body::soft_body_settings::SoftBodySettings,
    ) -> Option<Vec<natsel::math::types::Vec3>> {
        let count = settings.vertices.len();
        let mut parents: Vec<usize> = (0..count).collect();
        fn root(parents: &mut [usize], value: usize) -> usize {
            let mut index = value;
            while parents[index] != index {
                parents[index] = parents[parents[index]];
                index = parents[index];
            }
            index
        }
        for edge in &settings.edges {
            let a = root(&mut parents, edge.vertex.x as usize);
            let b = root(&mut parents, edge.vertex.y as usize);
            if a != b {
                parents[a.max(b)] = a.min(b);
            }
        }
        let roots: Vec<usize> = (0..count).map(|index| root(&mut parents, index)).collect();
        let mut unique: Vec<usize> = roots.clone();
        unique.sort_unstable();
        unique.dedup();
        if unique.len() <= 1 {
            return None;
        }
        let initial: Vec<natsel::math::types::Vec3> = settings
            .vertices
            .iter()
            .map(|vertex| vertex.position)
            .collect();
        let min_x = initial.iter().map(|p| p.x).fold(f32::MAX, f32::min);
        let max_x = initial.iter().map(|p| p.x).fold(-f32::MAX, f32::max);
        let max_edge = settings
            .edges
            .iter()
            .map(|edge| edge.rest_length)
            .fold(1.0f32, f32::max);
        let spacing = (max_x - min_x + 4.0 * max_edge).max(1.0);
        let component: BTreeMap<usize, usize> = unique
            .iter()
            .enumerate()
            .map(|(offset, value)| (*value, offset))
            .collect();
        for (vertex, root_id) in settings.vertices.iter_mut().zip(roots.iter()) {
            let offset = component
                .get(root_id)
                .copied()
                .expect("root came from unique");
            vertex.position.x += offset as f32 * spacing;
        }
        Some(initial)
    }

    /// `stepCharacters(_:)` — drive each stored character from its command, then
    /// publish state and cache the writeback so the next prepare does not read it as a
    /// teleport.
    pub(crate) fn step_characters(&mut self, context: &PhysicsStepContext) -> Vec<CharacterState> {
        let mut states = Vec::new();
        let mut entities: Vec<EntityID> = self.characters.keys().copied().collect();
        entities.sort_by_key(|entity| entity.raw_value());
        for entity in entities {
            let Some(mut record) = self.characters.remove(&entity) else {
                continue;
            };
            let config = record.descriptor.controller.clone();
            let command = context
                .character_commands
                .get(&entity)
                .cloned()
                .unwrap_or_default();

            if command.stance != record.stance {
                let half_height = if command.stance == CharacterStance::Standing {
                    config.standing_half_height
                } else {
                    config.crouching_half_height
                };
                if record.character.set_shape(
                    config.radius,
                    2.0 * (half_height + config.radius),
                    0.0,
                ) {
                    record.stance = command.stance;
                }
            }

            // Horizontal motion is commanded directly; vertical keeps the solver's value
            // unless the character is grounded.
            let mut velocity = record.character.linear_velocity;
            velocity.x = command.desired_velocity.x;
            velocity.z = command.desired_velocity.z;
            if record.character.ground_state()
                == natsel::character::character_virtual::CharacterGroundState::OnGround
            {
                velocity.y = command.desired_velocity.y.max(0.0);
                if command.jump_requested {
                    velocity.y = command.jump_speed.max(0.0);
                }
            }
            let gravity = NatselPhysicsBackend::nv(context.settings.gravity)
                * (context.step_delta_seconds as f32 * config.gravity_scale);
            velocity += gravity;
            record.character.linear_velocity = velocity;
            record.character.extended_update(
                context.step_delta_seconds as f32,
                NatselPhysicsBackend::nv(context.settings.gravity) * config.gravity_scale,
            );

            let ground = match record.character.ground_state() {
                natsel::character::character_virtual::CharacterGroundState::OnGround => {
                    CharacterGroundState::OnGround
                }
                natsel::character::character_virtual::CharacterGroundState::OnSteepGround => {
                    CharacterGroundState::OnSteepGround
                }
                natsel::character::character_virtual::CharacterGroundState::NotSupported => {
                    CharacterGroundState::NotSupported
                }
                natsel::character::character_virtual::CharacterGroundState::InAir => {
                    CharacterGroundState::InAir
                }
            };
            let rotation = NatselPhysicsBackend::sq(record.character.rotation);
            let foot = NatselPhysicsBackend::sv_pos(record.character.position());
            // Report the capsule centre, not the foot, so the state matches the authored
            // transform: undo the `center` offset through the same rotation.
            let center_offset =
                diffuse_math::simd::simd_compat::Quatf::from_vector(rotation).act(config.center);
            let reported_position = Float3::new(
                foot.x - center_offset.x,
                foot.y - center_offset.y,
                foot.z - center_offset.z,
            );
            let ground_body_id = record.character.ground_body_id();
            let ground_entity = self
                .bodies
                .iter()
                .find(|(_, body)| body.id == ground_body_id)
                .map(|(entity, _)| *entity)
                .or_else(|| {
                    self.soft_query_surfaces
                        .iter()
                        .find(|(_, surface)| surface.body == ground_body_id)
                        .map(|(entity, _)| *entity)
                });
            states.push(CharacterState::new(
                entity,
                reported_position,
                rotation,
                NatselPhysicsBackend::sv(record.character.linear_velocity),
                ground,
                NatselPhysicsBackend::sv(record.character.ground_normal()),
                NatselPhysicsBackend::sv(record.character.ground_velocity()),
                ground_entity,
                record.stance,
            ));

            // Record the writeback so the following prepare does not treat it as a
            // teleport.
            record.descriptor.world_transform =
                crate::runtime_world::WorldTransform::new(NatselPhysicsBackend::matrix(
                    reported_position,
                    rotation,
                    NatselPhysicsBackend::scale(record.descriptor.world_transform.matrix),
                ));
            self.characters.insert(entity, record);
        }
        states
    }

    /// `softStates()` — vertex positions and sleep state per body.
    pub(crate) fn soft_states(&self) -> Vec<SoftBodyMeshState> {
        let mut entities: Vec<EntityID> = self.soft_bodies.keys().copied().collect();
        entities.sort_by_key(|entity| entity.raw_value());
        entities
            .into_iter()
            .filter_map(|entity| {
                let record = self.soft_bodies.get(&entity)?;
                Some(SoftBodyMeshState::with_state(
                    entity,
                    self.world
                        .soft_body_vertex_positions(record.id)
                        .into_iter()
                        .map(NatselPhysicsBackend::sv_pos)
                        .collect(),
                    record.descriptor.topology.triangle_indices(),
                    !self.world.soft_body_is_awake(record.id),
                ))
            })
            .collect()
    }

    /// `vehicleStates()` — declared here so the deformables split owns the state
    /// reporting for every dynamic feature.
    pub(crate) fn vehicle_states(&self) -> Vec<VehicleState> {
        super::natsel_vehicles::vehicle_states(self)
    }
}

/// A built soft-body definition plus any rest pose that must be restored after the
/// components were moved apart for self-collision.
#[derive(Debug)]
pub(crate) struct SoftDefinition {
    pub(crate) definition: natsel::soft_body::soft_body_runtime::SoftBodyDef,
    pub(crate) initial_positions: Option<Vec<natsel::math::types::Vec3>>,
}

/// Marker so `CharacterCommand` stays referenced when the default is used.
const _: fn() -> CharacterCommand = CharacterCommand::default;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn soft_definition_rejects_invalid_topology() {
        use crate::physics::backend::physics_descriptors::{
            PhysicsSoftBodyDescriptor, PhysicsSoftBodyTopology,
        };
        use crate::physics::soft_bodies::soft_body::SoftBody;
        use crate::runtime_world::WorldTransform;

        let mut backend = NatselPhysicsBackend::new();
        let descriptor = PhysicsSoftBodyDescriptor::new(
            EntityID::new(1, 0),
            WorldTransform::IDENTITY,
            SoftBody::default(),
            PhysicsSoftBodyTopology::Invalid,
        );
        let error = backend.soft_definition(&descriptor).unwrap_err();
        assert_eq!(error.code, PhysicsBackendErrorCode::InvalidArgument);
        assert_eq!(
            error.message,
            "Soft body requires exactly one valid topology"
        );
    }

    #[test]
    fn soft_states_is_empty_without_bodies() {
        let backend = NatselPhysicsBackend::new();
        assert!(backend.soft_states().is_empty());
    }
}
