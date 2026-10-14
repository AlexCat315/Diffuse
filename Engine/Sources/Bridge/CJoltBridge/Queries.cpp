#include "Internal.hpp"

using namespace jolt;

// Raycast, overlap and sweep queries against the broad phase.

bool GuavaJoltContextImpl::raycast(const GuavaJoltRaycastQuery* query, const GuavaJoltQueryFilter* filter, GuavaJoltRaycastHit* out_hit) const {
            if (!query || !out_hit) return false;
            JPH::Vec3 direction(query->direction_x, query->direction_y, query->direction_z);
            const float direction_length = direction.Length();
            const float max_distance = std::max(query->max_distance, 0.0f);
            if (direction_length <= 1.0e-6f || max_distance <= 0.0f) return false;
            direction = direction / direction_length * max_distance;

            JPH::RRayCast ray(
                JPH::RVec3(query->origin_x, query->origin_y, query->origin_z),
                direction);
            MetadataBodyFilter body_filter(bodies.metadata, filter);
            JPH::RayCastResult hit;
            if (!physics_system.GetNarrowPhaseQuery().CastRay(ray, hit, {}, {}, body_filter)) {
                return false;
            }

            JPH::BodyLockRead lock(physics_system.GetBodyLockInterface(), hit.mBodyID);
            if (!lock.Succeeded()) return false;
            const JPH::Body& body = lock.GetBody();
            const uint64_t entity = body.GetUserData();
            auto metadata_it = bodies.metadata.find(entity);
            if (metadata_it == bodies.metadata.end()) return false;

            JPH::RVec3 position = ray.GetPointOnRay(hit.mFraction);
            JPH::Vec3 normal = body.GetWorldSpaceSurfaceNormal(hit.mSubShapeID2, position);
            const JPH::AABox& bounds = body.GetWorldSpaceBounds();

            out_hit->entity_id = entity;
            out_hit->distance = hit.mFraction * max_distance;
            out_hit->position_x = position.GetX();
            out_hit->position_y = position.GetY();
            out_hit->position_z = position.GetZ();
            out_hit->normal_x = normal.GetX();
            out_hit->normal_y = normal.GetY();
            out_hit->normal_z = normal.GetZ();
            fill_bounds(bounds,
                        out_hit->bounds_min_x, out_hit->bounds_min_y, out_hit->bounds_min_z,
                        out_hit->bounds_max_x, out_hit->bounds_max_y, out_hit->bounds_max_z);
            out_hit->sub_shape_id = hit.mSubShapeID2.GetValue();
            out_hit->is_trigger = metadata_it->second.is_trigger ? 1u : 0u;
            out_hit->reserved0 = 0;
            out_hit->reserved1 = 0;
            return true;
        }

uint32_t GuavaJoltContextImpl::raycast_all(const GuavaJoltRaycastQuery* query, const GuavaJoltQueryFilter* filter, GuavaJoltRaycastHit* out_hits, size_t hit_capacity) const {
        if (!query) return 0;
        JPH::Vec3 direction(query->direction_x, query->direction_y, query->direction_z);
        const float direction_length = direction.Length();
        const float max_distance = std::max(query->max_distance, 0.0f);
        if (direction_length <= 1.0e-6f || max_distance <= 0.0f) return 0;
        direction = direction / direction_length * max_distance;
        JPH::RRayCast ray(JPH::RVec3(query->origin_x, query->origin_y, query->origin_z), direction);
        MetadataBodyFilter body_filter(bodies.metadata, filter);
        JPH::AllHitCollisionCollector<JPH::CastRayCollector> collector;
        physics_system.GetNarrowPhaseQuery().CastRay(ray, {}, collector, {}, {}, body_filter);

        std::vector<GuavaJoltRaycastHit> hits;
        hits.reserve(collector.mHits.size());
        for (const JPH::RayCastResult& result : collector.mHits) {
            JPH::BodyLockRead lock(physics_system.GetBodyLockInterface(), result.mBodyID);
            if (!lock.Succeeded()) continue;
            const JPH::Body& body = lock.GetBody();
            const uint64_t entity = body.GetUserData();
            auto metadata_it = bodies.metadata.find(entity);
            if (metadata_it == bodies.metadata.end()) continue;
            const JPH::RVec3 position = ray.GetPointOnRay(result.mFraction);
            const JPH::Vec3 normal = body.GetWorldSpaceSurfaceNormal(result.mSubShapeID2, position);
            GuavaJoltRaycastHit hit {};
            hit.entity_id = entity;
            hit.distance = result.mFraction * max_distance;
            hit.position_x = position.GetX(); hit.position_y = position.GetY(); hit.position_z = position.GetZ();
            hit.normal_x = normal.GetX(); hit.normal_y = normal.GetY(); hit.normal_z = normal.GetZ();
            fill_bounds(body.GetWorldSpaceBounds(),
                hit.bounds_min_x, hit.bounds_min_y, hit.bounds_min_z,
                hit.bounds_max_x, hit.bounds_max_y, hit.bounds_max_z);
            hit.sub_shape_id = result.mSubShapeID2.GetValue();
            hit.is_trigger = metadata_it->second.is_trigger ? 1u : 0u;
            hits.push_back(hit);
        }
        std::sort(hits.begin(), hits.end(), [](const auto& lhs, const auto& rhs) {
            if (lhs.distance != rhs.distance) return lhs.distance < rhs.distance;
            if (lhs.entity_id != rhs.entity_id) return lhs.entity_id < rhs.entity_id;
            return lhs.sub_shape_id < rhs.sub_shape_id;
        });
        const size_t count = std::min(hit_capacity, hits.size());
        if (out_hits) for (size_t index = 0; index < count; ++index) out_hits[index] = hits[index];
        return static_cast<uint32_t>(hits.size());
        }

uint32_t GuavaJoltContextImpl::overlap_aabb(const GuavaJoltOverlapAABBQuery* query, const GuavaJoltQueryFilter* filter, GuavaJoltOverlapHit* out_hits, size_t hit_capacity) const {
            if (!query) return 0;
            JPH::AABox query_bounds = make_aabb(query->bounds_min_x, query->bounds_min_y, query->bounds_min_z,
                                                query->bounds_max_x, query->bounds_max_y, query->bounds_max_z);
            if (!query_bounds.IsValid()) return 0;
            const JPH::Vec3 half_extents = (query_bounds.mMax - query_bounds.mMin) * 0.5f;
            if (half_extents.GetX() < 0.0f || half_extents.GetY() < 0.0f || half_extents.GetZ() < 0.0f) {
                return 0;
            }

            JPH::BoxShapeSettings box_settings(half_extents);
            box_settings.SetEmbedded();
            JPH::ShapeSettings::ShapeResult shape_result = box_settings.Create();
            if (!shape_result.IsValid()) return 0;
            JPH::ShapeRefC shape = shape_result.Get();

            JPH::CollideShapeSettings collide_settings;
            MetadataBodyFilter body_filter(bodies.metadata, filter);
            JPH::ClosestHitPerBodyCollisionCollector<JPH::CollideShapeCollector> collector;
            const JPH::Vec3 center = (query_bounds.mMin + query_bounds.mMax) * 0.5f;
            physics_system.GetNarrowPhaseQuery().CollideShape(
                shape,
                JPH::Vec3::sOne(),
                JPH::RMat44::sTranslation(JPH::RVec3(center)),
                collide_settings,
                JPH::RVec3::sZero(),
                collector,
                {},
                {},
                body_filter,
                {});
            collector.Sort();

            std::vector<GuavaJoltOverlapHit> hits;
            hits.reserve(collector.mHits.size());
            for (const JPH::CollideShapeResult& result : collector.mHits) {
                JPH::BodyLockRead lock(physics_system.GetBodyLockInterface(), result.mBodyID2);
                if (!lock.Succeeded()) continue;
                const JPH::Body& body = lock.GetBody();
                const uint64_t entity = body.GetUserData();
                auto metadata_it = bodies.metadata.find(entity);
                if (metadata_it == bodies.metadata.end()) continue;

                GuavaJoltOverlapHit hit {};
                hit.entity_id = entity;
                fill_bounds(body.GetWorldSpaceBounds(),
                            hit.bounds_min_x, hit.bounds_min_y, hit.bounds_min_z,
                            hit.bounds_max_x, hit.bounds_max_y, hit.bounds_max_z);
                hit.is_trigger = metadata_it->second.is_trigger ? 1u : 0u;
                hit.sub_shape_id = result.mSubShapeID2.GetValue();
                hits.push_back(hit);
            }

            std::sort(hits.begin(), hits.end(), [](const auto& lhs, const auto& rhs) {
                return lhs.entity_id < rhs.entity_id;
            });
            const uint32_t max_results = query->max_results == 0 ? 0 : query->max_results;
            if (max_results != UINT32_MAX && hits.size() > max_results) {
                hits.resize(max_results);
            }
            if (out_hits && hit_capacity > 0) {
                const size_t count = std::min(hit_capacity, hits.size());
                for (size_t i = 0; i < count; ++i) out_hits[i] = hits[i];
            }
            return static_cast<uint32_t>(hits.size());
        }

uint32_t GuavaJoltContextImpl::overlap_shape(const GuavaJoltOverlapShapeQuery* query, const GuavaJoltQueryFilter* filter, GuavaJoltOverlapHit* out_hits, size_t hit_capacity) const {
        if (!query) return 0;
        JPH::ShapeRefC shape = build_query_shape(
            query->shape_type,
            query->box_half_extent_x,
            query->box_half_extent_y,
            query->box_half_extent_z,
            query->sphere_radius,
            query->capsule_radius,
            query->capsule_half_height);
        if (!shape) return 0;

        JPH::CollideShapeSettings collide_settings;
        MetadataBodyFilter body_filter(bodies.metadata, filter);
        JPH::ClosestHitPerBodyCollisionCollector<JPH::CollideShapeCollector> collector;
        physics_system.GetNarrowPhaseQuery().CollideShape(
            shape,
            JPH::Vec3::sOne(),
            query_transform(
                query->position_x,
                query->position_y,
                query->position_z,
                query->rotation_x,
                query->rotation_y,
                query->rotation_z,
                query->rotation_w),
            collide_settings,
            JPH::RVec3::sZero(),
            collector,
            {},
            {},
            body_filter,
            {});
        collector.Sort();

        std::vector<GuavaJoltOverlapHit> hits;
        hits.reserve(collector.mHits.size());
        for (const JPH::CollideShapeResult& result : collector.mHits) {
            JPH::BodyLockRead lock(physics_system.GetBodyLockInterface(), result.mBodyID2);
            if (!lock.Succeeded()) continue;
            const JPH::Body& body = lock.GetBody();
            const uint64_t entity = body.GetUserData();
            auto metadata_it = bodies.metadata.find(entity);
            if (metadata_it == bodies.metadata.end()) continue;

            GuavaJoltOverlapHit hit {};
            hit.entity_id = entity;
            fill_bounds(body.GetWorldSpaceBounds(),
                        hit.bounds_min_x, hit.bounds_min_y, hit.bounds_min_z,
                        hit.bounds_max_x, hit.bounds_max_y, hit.bounds_max_z);
            hit.is_trigger = metadata_it->second.is_trigger ? 1u : 0u;
            hit.sub_shape_id = result.mSubShapeID2.GetValue();
            hits.push_back(hit);
        }

        std::sort(hits.begin(), hits.end(), [](const auto& lhs, const auto& rhs) {
            return lhs.entity_id < rhs.entity_id;
        });
        const uint32_t max_results = query->max_results == 0 ? 0 : query->max_results;
        if (max_results != UINT32_MAX && hits.size() > max_results) {
            hits.resize(max_results);
        }
        if (out_hits && hit_capacity > 0) {
            const size_t count = std::min(hit_capacity, hits.size());
            for (size_t i = 0; i < count; ++i) out_hits[i] = hits[i];
        }
        return static_cast<uint32_t>(hits.size());
        }

bool GuavaJoltContextImpl::sweep_aabb(const GuavaJoltSweepAABBQuery* query, const GuavaJoltQueryFilter* filter, GuavaJoltSweepHit* out_hit) const {
            if (!query || !out_hit) return false;
            JPH::AABox query_bounds = make_aabb(query->bounds_min_x, query->bounds_min_y, query->bounds_min_z,
                                                query->bounds_max_x, query->bounds_max_y, query->bounds_max_z);
            if (!query_bounds.IsValid()) return false;

            JPH::Vec3 translation(query->translation_x, query->translation_y, query->translation_z);
            const float travel_distance = translation.Length();
            if (travel_distance <= 1.0e-6f) return false;

            JPH::BoxShapeSettings box_settings((query_bounds.mMax - query_bounds.mMin) * 0.5f);
            box_settings.SetEmbedded();
            JPH::ShapeSettings::ShapeResult shape_result = box_settings.Create();
            if (!shape_result.IsValid()) return false;
            JPH::ShapeRefC shape = shape_result.Get();

            const JPH::Vec3 center = (query_bounds.mMin + query_bounds.mMax) * 0.5f;
            JPH::RShapeCast shape_cast = JPH::RShapeCast::sFromWorldTransform(
                shape,
                JPH::Vec3::sOne(),
                JPH::RMat44::sTranslation(JPH::RVec3(center)),
                translation);
            JPH::ShapeCastSettings settings;
            settings.mReturnDeepestPoint = true;
            MetadataBodyFilter body_filter(bodies.metadata, filter);
            JPH::ClosestHitCollisionCollector<JPH::CastShapeCollector> collector;
            physics_system.GetNarrowPhaseQuery().CastShape(
                shape_cast,
                settings,
                JPH::RVec3(center),
                collector,
                {},
                {},
                body_filter,
                {});
            if (!collector.HadHit()) return false;

            const JPH::ShapeCastResult& result = collector.mHit;
            JPH::BodyLockRead lock(physics_system.GetBodyLockInterface(), result.mBodyID2);
            if (!lock.Succeeded()) return false;
            const JPH::Body& body = lock.GetBody();
            const uint64_t entity = body.GetUserData();
            auto metadata_it = bodies.metadata.find(entity);
            if (metadata_it == bodies.metadata.end()) return false;

            JPH::Vec3 normal = safe_normalized(-result.mPenetrationAxis, -translation / travel_distance);
            JPH::Vec3 hit_position = center + translation * result.mFraction;
            out_hit->entity_id = entity;
            out_hit->fraction = result.mFraction;
            out_hit->distance = result.mFraction * travel_distance;
            out_hit->position_x = hit_position.GetX();
            out_hit->position_y = hit_position.GetY();
            out_hit->position_z = hit_position.GetZ();
            out_hit->normal_x = normal.GetX();
            out_hit->normal_y = normal.GetY();
            out_hit->normal_z = normal.GetZ();
            fill_bounds(body.GetWorldSpaceBounds(),
                        out_hit->bounds_min_x, out_hit->bounds_min_y, out_hit->bounds_min_z,
                        out_hit->bounds_max_x, out_hit->bounds_max_y, out_hit->bounds_max_z);
            out_hit->sub_shape_id = result.mSubShapeID2.GetValue();
            out_hit->is_trigger = metadata_it->second.is_trigger ? 1u : 0u;
            out_hit->reserved0 = 0;
            out_hit->reserved1 = 0;
            return true;
        }

bool GuavaJoltContextImpl::sweep_shape(const GuavaJoltSweepShapeQuery* query, const GuavaJoltQueryFilter* filter, GuavaJoltSweepHit* out_hit) const {
        if (!query || !out_hit) return false;
        JPH::ShapeRefC shape = build_query_shape(
            query->shape_type,
            query->box_half_extent_x,
            query->box_half_extent_y,
            query->box_half_extent_z,
            query->sphere_radius,
            query->capsule_radius,
            query->capsule_half_height);
        if (!shape) return false;

        JPH::Vec3 translation(query->translation_x, query->translation_y, query->translation_z);
        const float travel_distance = translation.Length();
        if (travel_distance <= 1.0e-6f) return false;

        const JPH::RVec3 position(query->position_x, query->position_y, query->position_z);
        JPH::RShapeCast shape_cast = JPH::RShapeCast::sFromWorldTransform(
            shape,
            JPH::Vec3::sOne(),
            query_transform(
                query->position_x,
                query->position_y,
                query->position_z,
                query->rotation_x,
                query->rotation_y,
                query->rotation_z,
                query->rotation_w),
            translation);
        JPH::ShapeCastSettings settings;
        settings.mReturnDeepestPoint = true;
        MetadataBodyFilter body_filter(bodies.metadata, filter);
        JPH::ClosestHitCollisionCollector<JPH::CastShapeCollector> collector;
        physics_system.GetNarrowPhaseQuery().CastShape(
            shape_cast,
            settings,
            position,
            collector,
            {},
            {},
            body_filter,
            {});
        if (!collector.HadHit()) return false;

        const JPH::ShapeCastResult& result = collector.mHit;
        JPH::BodyLockRead lock(physics_system.GetBodyLockInterface(), result.mBodyID2);
        if (!lock.Succeeded()) return false;
        const JPH::Body& body = lock.GetBody();
        const uint64_t entity = body.GetUserData();
        auto metadata_it = bodies.metadata.find(entity);
        if (metadata_it == bodies.metadata.end()) return false;

        JPH::Vec3 normal = safe_normalized(-result.mPenetrationAxis, -translation / travel_distance);
        JPH::RVec3 hit_position = position + translation * result.mFraction;
        out_hit->entity_id = entity;
        out_hit->fraction = result.mFraction;
        out_hit->distance = result.mFraction * travel_distance;
        out_hit->position_x = hit_position.GetX();
        out_hit->position_y = hit_position.GetY();
        out_hit->position_z = hit_position.GetZ();
        out_hit->normal_x = normal.GetX();
        out_hit->normal_y = normal.GetY();
        out_hit->normal_z = normal.GetZ();
        fill_bounds(body.GetWorldSpaceBounds(),
                    out_hit->bounds_min_x, out_hit->bounds_min_y, out_hit->bounds_min_z,
                    out_hit->bounds_max_x, out_hit->bounds_max_y, out_hit->bounds_max_z);
        out_hit->sub_shape_id = result.mSubShapeID2.GetValue();
        out_hit->is_trigger = metadata_it->second.is_trigger ? 1u : 0u;
        out_hit->reserved0 = 0;
        out_hit->reserved1 = 0;
        return true;
        }

uint32_t GuavaJoltContextImpl::sweep_shape_all(const GuavaJoltSweepShapeQuery* query, const GuavaJoltQueryFilter* filter, GuavaJoltSweepHit* out_hits, size_t hit_capacity) const {
        if (!query) return 0;
        JPH::ShapeRefC shape = build_query_shape(
            query->shape_type,
            query->box_half_extent_x, query->box_half_extent_y, query->box_half_extent_z,
            query->sphere_radius, query->capsule_radius, query->capsule_half_height);
        if (!shape) return 0;
        const JPH::Vec3 translation(query->translation_x, query->translation_y, query->translation_z);
        const float travel_distance = translation.Length();
        if (travel_distance <= 1.0e-6f) return 0;
        const JPH::RMat44 transform = query_transform(
            query->position_x, query->position_y, query->position_z,
            query->rotation_x, query->rotation_y, query->rotation_z, query->rotation_w);
        JPH::RShapeCast shape_cast = JPH::RShapeCast::sFromWorldTransform(
            shape, JPH::Vec3::sOne(), transform, translation);
        JPH::ShapeCastSettings settings;
        settings.mReturnDeepestPoint = true;
        MetadataBodyFilter body_filter(bodies.metadata, filter);
        JPH::AllHitCollisionCollector<JPH::CastShapeCollector> collector;
        physics_system.GetNarrowPhaseQuery().CastShape(
            shape_cast, settings,
            JPH::RVec3(query->position_x, query->position_y, query->position_z),
            collector, {}, {}, body_filter, {});

        std::vector<GuavaJoltSweepHit> hits;
        hits.reserve(collector.mHits.size());
        for (const JPH::ShapeCastResult& result : collector.mHits) {
            JPH::BodyLockRead lock(physics_system.GetBodyLockInterface(), result.mBodyID2);
            if (!lock.Succeeded()) continue;
            const JPH::Body& body = lock.GetBody();
            const uint64_t entity = body.GetUserData();
            auto metadata_it = bodies.metadata.find(entity);
            if (metadata_it == bodies.metadata.end()) continue;
            const JPH::Vec3 normal = safe_normalized(-result.mPenetrationAxis, -translation / travel_distance);
            const JPH::Vec3 position = JPH::Vec3(query->position_x, query->position_y, query->position_z)
                + translation * result.mFraction;
            GuavaJoltSweepHit hit {};
            hit.entity_id = entity;
            hit.fraction = result.mFraction;
            hit.distance = result.mFraction * travel_distance;
            hit.position_x = position.GetX(); hit.position_y = position.GetY(); hit.position_z = position.GetZ();
            hit.normal_x = normal.GetX(); hit.normal_y = normal.GetY(); hit.normal_z = normal.GetZ();
            fill_bounds(body.GetWorldSpaceBounds(),
                hit.bounds_min_x, hit.bounds_min_y, hit.bounds_min_z,
                hit.bounds_max_x, hit.bounds_max_y, hit.bounds_max_z);
            hit.sub_shape_id = result.mSubShapeID2.GetValue();
            hit.is_trigger = metadata_it->second.is_trigger ? 1u : 0u;
            hits.push_back(hit);
        }
        std::sort(hits.begin(), hits.end(), [](const auto& lhs, const auto& rhs) {
            if (lhs.distance != rhs.distance) return lhs.distance < rhs.distance;
            if (lhs.entity_id != rhs.entity_id) return lhs.entity_id < rhs.entity_id;
            return lhs.sub_shape_id < rhs.sub_shape_id;
        });
        const size_t count = std::min(hit_capacity, hits.size());
        if (out_hits) for (size_t index = 0; index < count; ++index) out_hits[index] = hits[index];
        return static_cast<uint32_t>(hits.size());
        }

