#include "Internal.hpp"

using namespace jolt;

// Jolt 5.5 has no intra-soft-body collision switch. Its public vertex API
// permits external velocity / inverse-mass control but warns against direct
// position edits, so resolve deterministic vertex-face contacts as velocity
// constraints after the native step and let Jolt integrate them next frame.

// Soft body creation, mesh sync and vertex self-collision.


bool GuavaJoltContextImpl::destroy_soft_body(uint64_t entity) {
    auto existing = soft_bodies.ids.find(entity);
    if (existing == soft_bodies.ids.end()) return false;
    JPH::BodyInterface& bi = physics_system.GetBodyInterface();
    bi.RemoveBody(existing->second);
    bi.DestroyBody(existing->second);
    soft_bodies.ids.erase(existing);
    soft_bodies.self_collisions.erase(entity);
    bodies.metadata.erase(entity);
    return true;
    }

int32_t GuavaJoltContextImpl::self_collision_cell_coordinate(float value, float cell_size) {
    const double coordinate = std::floor(
        static_cast<double>(value) / static_cast<double>(cell_size));
    const double minimum = static_cast<double>(std::numeric_limits<int32_t>::min());
    const double maximum = static_cast<double>(std::numeric_limits<int32_t>::max());
    return static_cast<int32_t>(std::max(minimum, std::min(maximum, coordinate)));
    }

uint64_t GuavaJoltContextImpl::self_collision_edge_key(uint32_t a, uint32_t b) {
    const uint32_t low = std::min(a, b);
    const uint32_t high = std::max(a, b);
    return (static_cast<uint64_t>(low) << 32) | high;
    }

bool GuavaJoltContextImpl::self_collision_face_is_adjacent( uint32_t vertex_index, const SoftBodySelfCollisionFace& face, const std::unordered_set<uint64_t>& topology_edges) {
    for (uint32_t face_vertex : face.vertices) {
        if (face_vertex == vertex_index
            || topology_edges.find(self_collision_edge_key(vertex_index, face_vertex))
                != topology_edges.end()) {
            return true;
        }
    }
    return false;
    }

bool GuavaJoltContextImpl::apply_soft_body_self_collisions(float delta_seconds) {
    if (soft_bodies.self_collisions.empty()) return true;
    if (!std::isfinite(delta_seconds) || delta_seconds <= 0.0f) {
        last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
        return false;
    }

    std::vector<uint64_t> entities;
    entities.reserve(soft_bodies.self_collisions.size());
    for (const auto& entry : soft_bodies.self_collisions) entities.push_back(entry.first);
    std::sort(entities.begin(), entities.end());

    JPH::BodyInterface& body_interface = physics_system.GetBodyInterface();
    for (uint64_t entity : entities) {
        const auto body_it = soft_bodies.ids.find(entity);
        const auto collision_it = soft_bodies.self_collisions.find(entity);
        if (body_it == soft_bodies.ids.end() || collision_it == soft_bodies.self_collisions.end()) {
            last_error = GUAVA_JOLT_ERROR_UPDATE_FAILED;
            return false;
        }
        const NativeSoftBodySelfCollision& collision = collision_it->second;
        bool activate = false;
        {
            JPH::BodyLockWrite lock(
                physics_system.GetBodyLockInterface(), body_it->second);
            if (!lock.Succeeded() || !lock.GetBody().IsSoftBody()) {
                last_error = GUAVA_JOLT_ERROR_UPDATE_FAILED;
                return false;
            }
            JPH::Body& body = lock.GetBody();
            auto* properties = static_cast<JPH::SoftBodyMotionProperties*>(
                body.GetMotionProperties());
            JPH::Array<JPH::SoftBodyVertex>& vertices = properties->GetVertices();
            if (vertices.empty() || collision.faces.empty()) continue;

            for (const JPH::SoftBodyVertex& vertex : vertices) {
                if (!std::isfinite(vertex.mPosition.GetX())
                    || !std::isfinite(vertex.mPosition.GetY())
                    || !std::isfinite(vertex.mPosition.GetZ())) {
                    last_error = GUAVA_JOLT_ERROR_UPDATE_FAILED;
                    return false;
                }
            }

            using BucketMap = std::unordered_map<
                SoftBodySelfCollisionCell,
                std::vector<uint32_t>,
                SoftBodySelfCollisionCellHash>;
            BucketMap buckets;
            buckets.reserve(std::min<size_t>(collision.faces.size() * 4, 262144));
            std::vector<uint32_t> oversized_faces;
            constexpr uint64_t kMaximumCellsPerFace = 4096;
            constexpr uint64_t kMaximumBucketEntries = 2'000'000;
            uint64_t bucket_entry_count = 0;
            const float radius = collision.vertex_radius;

            for (uint32_t face_index = 0;
                 face_index < collision.faces.size();
                 ++face_index) {
                const SoftBodySelfCollisionFace& face = collision.faces[face_index];
                if (face.vertices[0] >= vertices.size()
                    || face.vertices[1] >= vertices.size()
                    || face.vertices[2] >= vertices.size()) {
                    last_error = GUAVA_JOLT_ERROR_UPDATE_FAILED;
                    return false;
                }
                const JPH::Vec3 a = vertices[face.vertices[0]].mPosition;
                const JPH::Vec3 b = vertices[face.vertices[1]].mPosition;
                const JPH::Vec3 c = vertices[face.vertices[2]].mPosition;
                const JPH::Vec3 minimum = JPH::Vec3::sMin(a, JPH::Vec3::sMin(b, c))
                    - JPH::Vec3::sReplicate(radius);
                const JPH::Vec3 maximum = JPH::Vec3::sMax(a, JPH::Vec3::sMax(b, c))
                    + JPH::Vec3::sReplicate(radius);
                const SoftBodySelfCollisionCell minimum_cell {
                    self_collision_cell_coordinate(minimum.GetX(), collision.cell_size),
                    self_collision_cell_coordinate(minimum.GetY(), collision.cell_size),
                    self_collision_cell_coordinate(minimum.GetZ(), collision.cell_size)
                };
                const SoftBodySelfCollisionCell maximum_cell {
                    self_collision_cell_coordinate(maximum.GetX(), collision.cell_size),
                    self_collision_cell_coordinate(maximum.GetY(), collision.cell_size),
                    self_collision_cell_coordinate(maximum.GetZ(), collision.cell_size)
                };
                const uint64_t span_x = static_cast<uint64_t>(
                    static_cast<int64_t>(maximum_cell.x)
                        - static_cast<int64_t>(minimum_cell.x) + 1);
                const uint64_t span_y = static_cast<uint64_t>(
                    static_cast<int64_t>(maximum_cell.y)
                        - static_cast<int64_t>(minimum_cell.y) + 1);
                const uint64_t span_z = static_cast<uint64_t>(
                    static_cast<int64_t>(maximum_cell.z)
                        - static_cast<int64_t>(minimum_cell.z) + 1);
                if (span_x > 64 || span_y > 64 || span_z > 64
                    || span_x * span_y * span_z > kMaximumCellsPerFace
                    || bucket_entry_count + span_x * span_y * span_z
                        > kMaximumBucketEntries) {
                    oversized_faces.push_back(face_index);
                    continue;
                }
                for (int64_t x = minimum_cell.x; x <= maximum_cell.x; ++x) {
                    for (int64_t y = minimum_cell.y; y <= maximum_cell.y; ++y) {
                        for (int64_t z = minimum_cell.z; z <= maximum_cell.z; ++z) {
                            buckets[SoftBodySelfCollisionCell{
                                static_cast<int32_t>(x),
                                static_cast<int32_t>(y),
                                static_cast<int32_t>(z)
                            }].push_back(face_index);
                            ++bucket_entry_count;
                        }
                    }
                }
            }

            std::vector<uint32_t> candidates;
            const float radius_squared = radius * radius;
            const float inverse_delta = 1.0f / delta_seconds;
            const float max_linear_velocity = properties->GetMaxLinearVelocity();
            for (uint32_t vertex_index = 0;
                 vertex_index < vertices.size();
                 ++vertex_index) {
                JPH::SoftBodyVertex& vertex = vertices[vertex_index];
                candidates.assign(oversized_faces.begin(), oversized_faces.end());
                const SoftBodySelfCollisionCell cell {
                    self_collision_cell_coordinate(
                        vertex.mPosition.GetX(), collision.cell_size),
                    self_collision_cell_coordinate(
                        vertex.mPosition.GetY(), collision.cell_size),
                    self_collision_cell_coordinate(
                        vertex.mPosition.GetZ(), collision.cell_size)
                };
                const auto bucket = buckets.find(cell);
                if (bucket != buckets.end()) {
                    candidates.insert(
                        candidates.end(), bucket->second.begin(), bucket->second.end());
                }
                std::sort(candidates.begin(), candidates.end());
                candidates.erase(
                    std::unique(candidates.begin(), candidates.end()), candidates.end());

                for (uint32_t face_index : candidates) {
                    const SoftBodySelfCollisionFace& face = collision.faces[face_index];
                    if (self_collision_face_is_adjacent(
                            vertex_index, face, collision.topology_edges)) {
                        continue;
                    }
                    JPH::SoftBodyVertex& face_a = vertices[face.vertices[0]];
                    JPH::SoftBodyVertex& face_b = vertices[face.vertices[1]];
                    JPH::SoftBodyVertex& face_c = vertices[face.vertices[2]];
                    const JPH::Vec3 relative_a = face_a.mPosition - vertex.mPosition;
                    const JPH::Vec3 relative_b = face_b.mPosition - vertex.mPosition;
                    const JPH::Vec3 relative_c = face_c.mPosition - vertex.mPosition;
                    JPH::uint32 closest_set = 0;
                    const JPH::Vec3 closest_offset =
                        JPH::ClosestPoint::GetClosestPointOnTriangle(
                            relative_a, relative_b, relative_c, closest_set);
                    const float distance_squared = closest_offset.LengthSq();
                    if (!std::isfinite(distance_squared)
                        || distance_squared >= radius_squared) {
                        continue;
                    }

                    const JPH::Vec3 closest = vertex.mPosition + closest_offset;
                    float weight_a = 0.0f;
                    float weight_b = 0.0f;
                    float weight_c = 0.0f;
                    JPH::ClosestPoint::GetBaryCentricCoordinates(
                        face_a.mPosition - closest,
                        face_b.mPosition - closest,
                        face_c.mPosition - closest,
                        weight_a, weight_b, weight_c);
                    weight_a = JPH::Clamp(weight_a, 0.0f, 1.0f);
                    weight_b = JPH::Clamp(weight_b, 0.0f, 1.0f);
                    weight_c = JPH::Clamp(weight_c, 0.0f, 1.0f);
                    const float weight_sum = weight_a + weight_b + weight_c;
                    if (weight_sum <= 1.0e-8f) continue;
                    weight_a /= weight_sum;
                    weight_b /= weight_sum;
                    weight_c /= weight_sum;

                    const float distance = std::sqrt(std::max(distance_squared, 0.0f));
                    JPH::Vec3 normal;
                    if (distance > 1.0e-6f) {
                        normal = -closest_offset / distance;
                    } else {
                        normal = (face_b.mPosition - face_a.mPosition)
                            .Cross(face_c.mPosition - face_a.mPosition)
                            .NormalizedOr(JPH::Vec3::sAxisY());
                        const JPH::Vec3 previous_closest =
                            weight_a * face_a.mPreviousPosition
                            + weight_b * face_b.mPreviousPosition
                            + weight_c * face_c.mPreviousPosition;
                        if ((vertex.mPreviousPosition - previous_closest).Dot(normal) < 0.0f) {
                            normal = -normal;
                        }
                    }

                    const float effective_inverse_mass = vertex.mInvMass
                        + weight_a * weight_a * face_a.mInvMass
                        + weight_b * weight_b * face_b.mInvMass
                        + weight_c * weight_c * face_c.mInvMass;
                    if (effective_inverse_mass <= 1.0e-8f) continue;
                    const JPH::Vec3 triangle_velocity =
                        weight_a * face_a.mVelocity
                        + weight_b * face_b.mVelocity
                        + weight_c * face_c.mVelocity;
                    const float relative_normal_velocity =
                        (vertex.mVelocity - triangle_velocity).Dot(normal);
                    const float separation_velocity = std::min(
                        max_linear_velocity,
                        std::max(0.0f, radius - distance) * inverse_delta);
                    const float required_velocity =
                        separation_velocity - relative_normal_velocity;
                    if (required_velocity > 0.0f) {
                        const float impulse = required_velocity / effective_inverse_mass;
                        vertex.mVelocity += vertex.mInvMass * impulse * normal;
                        face_a.mVelocity -= face_a.mInvMass * weight_a * impulse * normal;
                        face_b.mVelocity -= face_b.mInvMass * weight_b * impulse * normal;
                        face_c.mVelocity -= face_c.mInvMass * weight_c * impulse * normal;
                    }
                    vertex.mHasContact = true;
                    activate = true;
                }
            }

            if (activate) {
                JPH::Vec3 average_velocity = JPH::Vec3::sZero();
                for (JPH::SoftBodyVertex& vertex : vertices) {
                    const float speed_squared = vertex.mVelocity.LengthSq();
                    if (max_linear_velocity <= 0.0f) {
                        vertex.mVelocity = JPH::Vec3::sZero();
                    } else if (speed_squared > max_linear_velocity * max_linear_velocity) {
                        vertex.mVelocity *= max_linear_velocity / std::sqrt(speed_squared);
                    }
                    average_velocity += vertex.mVelocity;
                }
                average_velocity /= static_cast<float>(vertices.size());
                properties->SetLinearVelocityClamped(
                    body.GetCenterOfMassTransform().Multiply3x3(average_velocity));
            }
        }
        if (activate) body_interface.ActivateBody(body_it->second);
    }
    return true;
    }

bool GuavaJoltContextImpl::create_soft_body(const GuavaJoltSoftBodyDesc& desc) {
    const bool is_grid = desc.topology_kind == 0;
    const bool is_surface = desc.topology_kind == 1;
    if ((!is_grid && !is_surface)
        || (is_grid && (desc.grid_size_x < 2 || desc.grid_size_z < 2
            || desc.grid_size_x > 512 || desc.grid_size_z > 512
            || !std::isfinite(desc.spacing) || desc.spacing <= 0.0f))
        || (is_surface && (desc.surface_vertex_count < 3
            || desc.surface_vertex_count > 262144
            || !desc.surface_positions_xyz
            || desc.surface_triangle_index_count < 3
            || desc.surface_triangle_index_count > 1572864
            || desc.surface_triangle_index_count % 3 != 0
            || !desc.surface_triangle_indices))
        || (!is_surface && desc.tetrahedron_index_count != 0)
        || desc.tetrahedron_index_count > 1048576
        || desc.tetrahedron_index_count % 4 != 0
        || (desc.tetrahedron_index_count > 0 && !desc.tetrahedron_indices)
        || !std::isfinite(desc.vertex_mass) || desc.vertex_mass <= 0.0f
        || !std::isfinite(desc.position_x)
        || !std::isfinite(desc.position_y)
        || !std::isfinite(desc.position_z)
        || !std::isfinite(desc.rotation_x)
        || !std::isfinite(desc.rotation_y)
        || !std::isfinite(desc.rotation_z)
        || !std::isfinite(desc.rotation_w)
        || !std::isfinite(desc.scale_x) || desc.scale_x <= 1.0e-6f
        || !std::isfinite(desc.scale_y) || desc.scale_y <= 1.0e-6f
        || !std::isfinite(desc.scale_z) || desc.scale_z <= 1.0e-6f
        || !std::isfinite(desc.compliance) || desc.compliance < 0.0f
        || !std::isfinite(desc.shear_compliance) || desc.shear_compliance < 0.0f
        || !std::isfinite(desc.bend_compliance) || desc.bend_compliance < 0.0f
        || !std::isfinite(desc.volume_compliance) || desc.volume_compliance < 0.0f
        || !std::isfinite(desc.pressure) || desc.pressure < 0.0f
        || !std::isfinite(desc.linear_damping) || desc.linear_damping < 0.0f
        || !std::isfinite(desc.friction) || desc.friction < 0.0f
        || !std::isfinite(desc.restitution)
        || desc.restitution < 0.0f || desc.restitution > 1.0f
        || !std::isfinite(desc.gravity_factor)
        || !std::isfinite(desc.vertex_radius) || desc.vertex_radius < 0.0f
        || !std::isfinite(desc.max_linear_velocity)
        || desc.max_linear_velocity < 0.0f
        || desc.bend_type > 2
        || desc.allow_sleep > 1
        || desc.faces_double_sided > 1
        || desc.self_collision > 1
        || desc.layer_id >= 16
        || (desc.fixed_vertex_count > 0 && !desc.fixed_vertices)
        || (desc.self_collision != 0 && desc.vertex_radius <= 0.0f)) {
        last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
        return false;
    }
    const uint64_t vertex_count64 = is_grid
        ? static_cast<uint64_t>(desc.grid_size_x) * static_cast<uint64_t>(desc.grid_size_z)
        : static_cast<uint64_t>(desc.surface_vertex_count);
    if (vertex_count64 > UINT32_MAX) {
        last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
        return false;
    }
    const uint32_t vertex_count = static_cast<uint32_t>(vertex_count64);
    std::unordered_set<uint32_t> fixed_vertices;
    fixed_vertices.reserve(desc.fixed_vertex_count);
    for (uint32_t index = 0; index < desc.fixed_vertex_count; ++index) {
        if (desc.fixed_vertices[index] >= vertex_count) {
            last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
            return false;
        }
        fixed_vertices.insert(desc.fixed_vertices[index]);
    }

    JPH::Ref<JPH::SoftBodySharedSettings> shared = new JPH::SoftBodySharedSettings;
    shared->mVertices.reserve(vertex_count);
    const float inverse_mass = 1.0f / desc.vertex_mass;
    if (is_grid) {
        const float offset_x = -0.5f * desc.spacing * static_cast<float>(desc.grid_size_x - 1);
        const float offset_z = -0.5f * desc.spacing * static_cast<float>(desc.grid_size_z - 1);
        for (uint32_t z = 0; z < desc.grid_size_z; ++z) {
            for (uint32_t x = 0; x < desc.grid_size_x; ++x) {
                const uint32_t index = x + z * desc.grid_size_x;
                const float position_x =
                    (offset_x + static_cast<float>(x) * desc.spacing) * desc.scale_x;
                const float position_z =
                    (offset_z + static_cast<float>(z) * desc.spacing) * desc.scale_z;
                if (!std::isfinite(position_x) || !std::isfinite(position_z)) {
                    last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
                    return false;
                }
                JPH::SoftBodySharedSettings::Vertex vertex;
                JPH::Vec3(position_x, 0.0f, position_z).StoreFloat3(&vertex.mPosition);
                vertex.mInvMass = fixed_vertices.find(index) != fixed_vertices.end()
                    ? 0.0f : inverse_mass;
                shared->mVertices.push_back(vertex);
            }
        }
    } else {
        for (uint32_t index = 0; index < vertex_count; ++index) {
            const float x = desc.surface_positions_xyz[index * 3];
            const float y = desc.surface_positions_xyz[index * 3 + 1];
            const float z = desc.surface_positions_xyz[index * 3 + 2];
            const float scaled_x = x * desc.scale_x;
            const float scaled_y = y * desc.scale_y;
            const float scaled_z = z * desc.scale_z;
            if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)
                || !std::isfinite(scaled_x) || !std::isfinite(scaled_y)
                || !std::isfinite(scaled_z)) {
                last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
                return false;
            }
            JPH::SoftBodySharedSettings::Vertex vertex;
            JPH::Vec3(scaled_x, scaled_y, scaled_z).StoreFloat3(&vertex.mPosition);
            vertex.mInvMass = fixed_vertices.find(index) != fixed_vertices.end()
                ? 0.0f : inverse_mass;
            shared->mVertices.push_back(vertex);
        }
    }
    if (is_grid) {
        auto vertex_index = [&desc](uint32_t x, uint32_t z) {
            return x + z * desc.grid_size_x;
        };
        for (uint32_t z = 0; z + 1 < desc.grid_size_z; ++z) {
            for (uint32_t x = 0; x + 1 < desc.grid_size_x; ++x) {
                shared->AddFace(JPH::SoftBodySharedSettings::Face(
                    vertex_index(x, z),
                    vertex_index(x, z + 1),
                    vertex_index(x + 1, z + 1)));
                shared->AddFace(JPH::SoftBodySharedSettings::Face(
                    vertex_index(x, z),
                    vertex_index(x + 1, z + 1),
                    vertex_index(x + 1, z)));
            }
        }
    } else {
        for (uint32_t index = 0; index < desc.surface_triangle_index_count; index += 3) {
            const uint32_t i0 = desc.surface_triangle_indices[index];
            const uint32_t i1 = desc.surface_triangle_indices[index + 1];
            const uint32_t i2 = desc.surface_triangle_indices[index + 2];
            if (i0 >= vertex_count || i1 >= vertex_count || i2 >= vertex_count
                || i0 == i1 || i1 == i2 || i0 == i2) {
                last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
                return false;
            }
            const auto component = [&desc](uint32_t vertex, uint32_t axis) {
                const float scale = axis == 0 ? desc.scale_x
                    : axis == 1 ? desc.scale_y : desc.scale_z;
                return desc.surface_positions_xyz[vertex * 3 + axis] * scale;
            };
            const float ax = component(i1, 0) - component(i0, 0);
            const float ay = component(i1, 1) - component(i0, 1);
            const float az = component(i1, 2) - component(i0, 2);
            const float bx = component(i2, 0) - component(i0, 0);
            const float by = component(i2, 1) - component(i0, 1);
            const float bz = component(i2, 2) - component(i0, 2);
            const float cross_x = ay * bz - az * by;
            const float cross_y = az * bx - ax * bz;
            const float cross_z = ax * by - ay * bx;
            const float area_squared = cross_x * cross_x
                + cross_y * cross_y + cross_z * cross_z;
            if (!std::isfinite(area_squared) || area_squared <= 1.0e-16f) {
                last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
                return false;
            }
            shared->AddFace(JPH::SoftBodySharedSettings::Face(i0, i1, i2));
        }
    }
    const JPH::SoftBodySharedSettings::VertexAttributes attributes(
        std::max(0.0f, desc.compliance),
        std::max(0.0f, desc.shear_compliance),
        std::max(0.0f, desc.bend_compliance));
    const JPH::SoftBodySharedSettings::EBendType bend_type =
        desc.bend_type == 2
            ? JPH::SoftBodySharedSettings::EBendType::Dihedral
            : desc.bend_type == 1
                ? JPH::SoftBodySharedSettings::EBendType::Distance
                : JPH::SoftBodySharedSettings::EBendType::None;
    shared->CreateConstraints(&attributes, 1, bend_type);
    if (desc.tetrahedron_index_count > 0) {
        std::unordered_set<uint64_t> edges;
        edges.reserve(shared->mEdgeConstraints.size()
            + static_cast<size_t>(desc.tetrahedron_index_count) * 3 / 2);
        const auto edge_key = [](uint32_t a, uint32_t b) {
            const uint32_t low = std::min(a, b);
            const uint32_t high = std::max(a, b);
            return (static_cast<uint64_t>(low) << 32) | high;
        };
        for (const JPH::SoftBodySharedSettings::Edge& edge : shared->mEdgeConstraints) {
            edges.insert(edge_key(edge.mVertex[0], edge.mVertex[1]));
        }
        const auto component = [&desc](uint32_t vertex, uint32_t axis) {
            const float scale = axis == 0 ? desc.scale_x
                : axis == 1 ? desc.scale_y : desc.scale_z;
            return desc.surface_positions_xyz[vertex * 3 + axis] * scale;
        };
        const auto add_edge = [&shared, &edges, &edge_key, &desc](uint32_t a, uint32_t b) {
            if (edges.insert(edge_key(a, b)).second) {
                shared->mEdgeConstraints.push_back(
                    JPH::SoftBodySharedSettings::Edge(a, b, desc.compliance));
            }
        };
        for (uint32_t index = 0; index < desc.tetrahedron_index_count; index += 4) {
            const uint32_t i0 = desc.tetrahedron_indices[index];
            const uint32_t i1 = desc.tetrahedron_indices[index + 1];
            const uint32_t i2 = desc.tetrahedron_indices[index + 2];
            const uint32_t i3 = desc.tetrahedron_indices[index + 3];
            if (i0 >= vertex_count || i1 >= vertex_count
                || i2 >= vertex_count || i3 >= vertex_count
                || i0 == i1 || i0 == i2 || i0 == i3
                || i1 == i2 || i1 == i3 || i2 == i3) {
                last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
                return false;
            }
            const float ax = component(i0, 0) - component(i3, 0);
            const float ay = component(i0, 1) - component(i3, 1);
            const float az = component(i0, 2) - component(i3, 2);
            const float bx = component(i1, 0) - component(i3, 0);
            const float by = component(i1, 1) - component(i3, 1);
            const float bz = component(i1, 2) - component(i3, 2);
            const float cx = component(i2, 0) - component(i3, 0);
            const float cy = component(i2, 1) - component(i3, 1);
            const float cz = component(i2, 2) - component(i3, 2);
            const float six_volume = ax * (by * cz - bz * cy)
                - ay * (bx * cz - bz * cx)
                + az * (bx * cy - by * cx);
            if (!std::isfinite(six_volume) || std::abs(six_volume) <= 1.0e-12f) {
                last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
                return false;
            }
            add_edge(i0, i1);
            add_edge(i0, i2);
            add_edge(i0, i3);
            add_edge(i1, i2);
            add_edge(i1, i3);
            add_edge(i2, i3);
            shared->mVolumeConstraints.push_back(
                JPH::SoftBodySharedSettings::Volume(
                    i0, i1, i2, i3, desc.volume_compliance));
        }
        shared->CalculateEdgeLengths();
        shared->CalculateVolumeConstraintVolumes();
    }
    shared->Optimize();

    NativeSoftBodySelfCollision native_self_collision;
    if (desc.self_collision != 0) {
        native_self_collision.vertex_radius = desc.vertex_radius;
        native_self_collision.faces.reserve(shared->mFaces.size());
        double total_edge_length = 0.0;
        uint64_t edge_sample_count = 0;
        for (const JPH::SoftBodySharedSettings::Face& face : shared->mFaces) {
            native_self_collision.faces.push_back(SoftBodySelfCollisionFace{{
                face.mVertex[0], face.mVertex[1], face.mVertex[2]
            }});
            for (uint32_t edge = 0; edge < 3; ++edge) {
                const JPH::Vec3 a(shared->mVertices[face.mVertex[edge]].mPosition);
                const JPH::Vec3 b(shared->mVertices[face.mVertex[(edge + 1) % 3]].mPosition);
                total_edge_length += static_cast<double>((b - a).Length());
                ++edge_sample_count;
            }
        }
        const float average_edge_length = edge_sample_count > 0
            ? static_cast<float>(total_edge_length / static_cast<double>(edge_sample_count))
            : desc.vertex_radius * 2.0f;
        native_self_collision.cell_size = std::max(
            desc.vertex_radius * 2.0f,
            std::max(average_edge_length, 1.0e-4f));
        native_self_collision.topology_edges.reserve(shared->mEdgeConstraints.size());
        for (const JPH::SoftBodySharedSettings::Edge& edge : shared->mEdgeConstraints) {
            const uint32_t low = std::min(edge.mVertex[0], edge.mVertex[1]);
            const uint32_t high = std::max(edge.mVertex[0], edge.mVertex[1]);
            native_self_collision.topology_edges.insert(
                (static_cast<uint64_t>(low) << 32) | high);
        }
    }

    JPH::SoftBodyCreationSettings settings(
        shared,
        JPH::RVec3(desc.position_x, desc.position_y, desc.position_z),
        normalized_quat(desc.rotation_x, desc.rotation_y, desc.rotation_z, desc.rotation_w),
        Layers::MOVING);
    settings.mUserData = desc.entity_id;
    settings.mNumIterations = std::max<uint32_t>(1, std::min<uint32_t>(desc.solver_iterations, 128));
    settings.mLinearDamping = std::max(0.0f, desc.linear_damping);
    settings.mMaxLinearVelocity = std::max(0.0f, desc.max_linear_velocity);
    settings.mRestitution = JPH::Clamp(desc.restitution, 0.0f, 1.0f);
    settings.mFriction = std::max(0.0f, desc.friction);
    settings.mPressure = std::max(0.0f, desc.pressure);
    settings.mGravityFactor = desc.gravity_factor;
    settings.mVertexRadius = std::max(0.0f, desc.vertex_radius);
    settings.mAllowSleeping = desc.allow_sleep != 0;
    settings.mFacesDoubleSided = desc.faces_double_sided != 0;

    JPH::BodyInterface& bi = physics_system.GetBodyInterface();
    const JPH::BodyID body_id = bi.CreateAndAddSoftBody(
        settings, JPH::EActivation::Activate);
    if (body_id.IsInvalid()) {
        last_error = GUAVA_JOLT_ERROR_BODY_CREATION_FAILED;
        return false;
    }
    soft_bodies.ids[desc.entity_id] = body_id;
    if (desc.self_collision != 0) {
        soft_bodies.self_collisions[desc.entity_id] = std::move(native_self_collision);
    }
    bodies.metadata[desc.entity_id] = BodyMetadata{
        false,
        desc.layer_id,
        desc.layer_mask
    };
    return true;
    }

bool GuavaJoltContextImpl::sync_soft_bodies( const GuavaJoltSoftBodyDesc* upserts, size_t upsert_count, const uint64_t* removals, size_t removal_count, bool full_snapshot, GuavaJoltSoftBodySyncStats* out_stats) {
    last_error = GUAVA_JOLT_ERROR_NONE;
    if (!out_stats
        || (upsert_count > 0 && !upserts)
        || (removal_count > 0 && !removals)) {
        last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
        return false;
    }
    *out_stats = GuavaJoltSoftBodySyncStats{};

    std::unordered_map<uint64_t, const GuavaJoltSoftBodyDesc*> incoming;
    incoming.reserve(upsert_count);
    for (size_t index = 0; index < upsert_count; ++index) {
        incoming[upserts[index].entity_id] = &upserts[index];
    }
    std::vector<uint64_t> stale;
    if (full_snapshot) {
        for (const auto& entry : soft_bodies.ids) {
            if (incoming.find(entry.first) == incoming.end()) stale.push_back(entry.first);
        }
    } else if (removal_count > 0) {
        stale.assign(removals, removals + removal_count);
    }
    std::sort(stale.begin(), stale.end());
    stale.erase(std::unique(stale.begin(), stale.end()), stale.end());
    for (uint64_t entity : stale) {
        if (destroy_soft_body(entity)) ++out_stats->removed_soft_bodies;
    }

    std::vector<uint64_t> ids;
    ids.reserve(incoming.size());
    for (const auto& entry : incoming) ids.push_back(entry.first);
    std::sort(ids.begin(), ids.end());
    for (uint64_t entity : ids) {
        if (bodies.ids.find(entity) != bodies.ids.end()) {
            last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
            return false;
        }
        if (destroy_soft_body(entity)) ++out_stats->removed_soft_bodies;
        if (!create_soft_body(*incoming[entity])) return false;
        ++out_stats->synchronized_soft_bodies;
    }
    return true;
    }

uint32_t GuavaJoltContextImpl::copy_soft_body_states( GuavaJoltSoftBodyState* out_states, size_t state_capacity, float* out_positions_xyz, size_t vertex_capacity, uint32_t* out_vertex_count) {
    last_error = GUAVA_JOLT_ERROR_NONE;
    if (!out_vertex_count
        || (state_capacity > 0 && !out_states)
        || (vertex_capacity > 0 && !out_positions_xyz)) {
        last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
        return 0;
    }
    *out_vertex_count = 0;
    std::vector<uint64_t> ids;
    ids.reserve(soft_bodies.ids.size());
    for (const auto& entry : soft_bodies.ids) ids.push_back(entry.first);
    std::sort(ids.begin(), ids.end());
    if (ids.size() > state_capacity) {
        last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
        return 0;
    }

    size_t required_vertices = 0;
    for (uint64_t entity : ids) {
        JPH::BodyLockRead lock(
            physics_system.GetBodyLockInterface(), soft_bodies.ids[entity]);
        if (!lock.Succeeded() || !lock.GetBody().IsSoftBody()) {
            last_error = GUAVA_JOLT_ERROR_UPDATE_FAILED;
            return 0;
        }
        const auto* properties = static_cast<const JPH::SoftBodyMotionProperties*>(
            lock.GetBody().GetMotionProperties());
        required_vertices += properties->GetVertices().size();
    }
    if (required_vertices > vertex_capacity || required_vertices > UINT32_MAX) {
        last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
        return 0;
    }

    size_t vertex_offset = 0;
    size_t state_index = 0;
    const JPH::BodyInterface& bi = physics_system.GetBodyInterface();
    for (uint64_t entity : ids) {
        JPH::BodyLockRead lock(
            physics_system.GetBodyLockInterface(), soft_bodies.ids[entity]);
        const JPH::Body& body = lock.GetBody();
        const auto* properties = static_cast<const JPH::SoftBodyMotionProperties*>(
            body.GetMotionProperties());
        GuavaJoltSoftBodyState& state = out_states[state_index++];
        state = GuavaJoltSoftBodyState{};
        state.entity_id = entity;
        state.vertex_offset = static_cast<uint32_t>(vertex_offset);
        state.vertex_count = static_cast<uint32_t>(properties->GetVertices().size());
        state.is_sleeping = bi.IsActive(soft_bodies.ids[entity]) ? 0 : 1;
        const JPH::RMat44 center_of_mass = body.GetCenterOfMassTransform();
        for (const JPH::SoftBodyVertex& vertex : properties->GetVertices()) {
            const JPH::RVec3 position = center_of_mass * vertex.mPosition;
            out_positions_xyz[vertex_offset * 3] = static_cast<float>(position.GetX());
            out_positions_xyz[vertex_offset * 3 + 1] = static_cast<float>(position.GetY());
            out_positions_xyz[vertex_offset * 3 + 2] = static_cast<float>(position.GetZ());
            ++vertex_offset;
        }
    }
    *out_vertex_count = static_cast<uint32_t>(vertex_offset);
    return static_cast<uint32_t>(state_index);
    }

