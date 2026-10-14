#include "Internal.hpp"

using namespace jolt;

// Character virtuals, their capsule shapes and per-step commands.


bool GuavaJoltContextImpl::character_shape_changed( const GuavaJoltCharacterDesc& lhs, const GuavaJoltCharacterDesc& rhs) {
    return lhs.radius != rhs.radius
        || lhs.standing_half_height != rhs.standing_half_height
        || lhs.crouching_half_height != rhs.crouching_half_height
        || lhs.center_x != rhs.center_x
        || lhs.center_y != rhs.center_y
        || lhs.center_z != rhs.center_z
        || lhs.skin_width != rhs.skin_width;
    }

JPH::RefConst<JPH::Shape> GuavaJoltContextImpl::create_character_shape(float half_height, float radius) {
    JPH::CapsuleShapeSettings capsule_settings(
        std::max(half_height, 0.01f),
        std::max(radius, 0.01f));
    JPH::ShapeSettings::ShapeResult capsule_result = capsule_settings.Create();
    if (!capsule_result.IsValid()) return nullptr;

    // CharacterVirtual treats its position as the character's ground/foot
    // position. Keep the capsule above that origin as recommended by Jolt.
    const float center_height = std::max(half_height, 0.01f) + std::max(radius, 0.01f);
    JPH::RotatedTranslatedShapeSettings translated_settings(
        JPH::Vec3(0, center_height, 0),
        JPH::Quat::sIdentity(),
        capsule_result.Get());
    JPH::ShapeSettings::ShapeResult translated_result = translated_settings.Create();
    return translated_result.IsValid() ? translated_result.Get() : nullptr;
    }

std::unique_ptr<JPH::CharacterVirtual> GuavaJoltContextImpl::create_character(const GuavaJoltCharacterDesc& desc) {
    JPH::RefConst<JPH::Shape> shape = create_character_shape(
        desc.standing_half_height,
        desc.radius);
    if (shape == nullptr) {
        last_error = GUAVA_JOLT_ERROR_INVALID_SHAPE;
        return nullptr;
    }

    JPH::CharacterVirtualSettings settings;
    settings.mShape = shape;
    settings.mShapeOffset = JPH::Vec3(desc.center_x, desc.center_y, desc.center_z);
    settings.mSupportingVolume = JPH::Plane(
        JPH::Vec3::sAxisY(),
        -2.0f * std::max(desc.standing_half_height, 0.01f));
    settings.mCharacterPadding = std::max(desc.skin_width, 0.001f);
    settings.mMass = std::max(desc.mass, 0.01f);
    settings.mMaxStrength = std::max(desc.max_strength, 0.0f);
    settings.mUp = JPH::Vec3::sAxisY();
    auto character = std::make_unique<JPH::CharacterVirtual>(
        &settings,
        JPH::RVec3(desc.position_x, desc.position_y, desc.position_z),
        JPH::Quat(desc.rotation_x, desc.rotation_y, desc.rotation_z, desc.rotation_w),
        desc.entity_id,
        &physics_system);
    character->SetMaxSlopeAngle(desc.max_slope_radians);
    return character;
    }

bool GuavaJoltContextImpl::sync_characters(const GuavaJoltCharacterDesc* descriptors, size_t count) {
    last_error = GUAVA_JOLT_ERROR_NONE;
    if (count > 0 && !descriptors) {
        last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
        return false;
    }

    std::unordered_map<uint64_t, const GuavaJoltCharacterDesc*> incoming;
    for (size_t i = 0; i < count; ++i) incoming[descriptors[i].entity_id] = &descriptors[i];
    for (auto it = characters.begin(); it != characters.end();) {
        if (incoming.find(it->first) == incoming.end()) it = characters.erase(it);
        else ++it;
    }

    std::vector<uint64_t> ids;
    ids.reserve(incoming.size());
    for (const auto& item : incoming) ids.push_back(item.first);
    std::sort(ids.begin(), ids.end());
    for (uint64_t entity : ids) {
        const GuavaJoltCharacterDesc& desc = *incoming[entity];
        auto existing = characters.find(entity);
        if (existing == characters.end() || character_shape_changed(existing->second.desc, desc)) {
            auto character = create_character(desc);
            if (!character) return false;
            NativeCharacter native;
            native.character = std::move(character);
            native.desc = desc;
            characters[entity] = std::move(native);
            continue;
        }
        NativeCharacter& native = existing->second;
        native.desc = desc;
        native.character->SetPosition(JPH::RVec3(desc.position_x, desc.position_y, desc.position_z));
        native.character->SetRotation(JPH::Quat(
            desc.rotation_x, desc.rotation_y, desc.rotation_z, desc.rotation_w));
        native.character->SetMass(std::max(desc.mass, 0.01f));
        native.character->SetMaxStrength(std::max(desc.max_strength, 0.0f));
        native.character->SetMaxSlopeAngle(desc.max_slope_radians);
    }
    return true;
    }

uint32_t GuavaJoltContextImpl::step_characters( const GuavaJoltStepConfig* config, const GuavaJoltCharacterCommand* commands, size_t command_count, GuavaJoltCharacterState* out_states, size_t state_capacity) {
    if (!config || (command_count > 0 && !commands) || (state_capacity > 0 && !out_states)) {
        last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
        return 0;
    }
    std::unordered_map<uint64_t, const GuavaJoltCharacterCommand*> commands_by_entity;
    for (size_t i = 0; i < command_count; ++i) {
        commands_by_entity[commands[i].entity_id] = &commands[i];
    }

    std::vector<uint64_t> ids;
    ids.reserve(characters.size());
    for (const auto& item : characters) ids.push_back(item.first);
    std::sort(ids.begin(), ids.end());

    uint32_t written = 0;
    for (uint64_t entity : ids) {
        NativeCharacter& native = characters[entity];
        JPH::CharacterVirtual& character = *native.character;
        CharacterMetadataBodyFilter body_filter(
            bodies.metadata, native.desc.layer_id, native.desc.layer_mask);
        const auto broadphase_filter = physics_system.GetDefaultBroadPhaseLayerFilter(Layers::MOVING);
        const auto layer_filter = physics_system.GetDefaultLayerFilter(Layers::MOVING);

        const GuavaJoltCharacterCommand* command = nullptr;
        auto command_it = commands_by_entity.find(entity);
        if (command_it != commands_by_entity.end()) command = command_it->second;
        const uint8_t requested_stance = command ? command->stance : native.stance;
        if (requested_stance != native.stance) {
            const float half_height = requested_stance == 1
                ? native.desc.crouching_half_height
                : native.desc.standing_half_height;
            JPH::RefConst<JPH::Shape> shape = create_character_shape(
                half_height,
                native.desc.radius);
            if (shape != nullptr
                && character.SetShape(
                    shape,
                    0.0f,
                    broadphase_filter,
                    layer_filter,
                    body_filter,
                    {},
                    *temp_allocator)) {
                native.stance = requested_stance;
            }
        }

        const JPH::Vec3 gravity(
            config->gravity_x * native.desc.gravity_scale,
            config->gravity_y * native.desc.gravity_scale,
            config->gravity_z * native.desc.gravity_scale);
        const JPH::Vec3 up = character.GetUp();
        JPH::Vec3 velocity = character.GetLinearVelocity();
        float vertical_speed = velocity.Dot(up);
        const bool grounded = character.GetGroundState() == JPH::CharacterBase::EGroundState::OnGround;
        if (grounded && vertical_speed < 0.0f) vertical_speed = 0.0f;
        if (command && command->jump_requested && grounded) {
            vertical_speed = std::max(command->jump_speed, 0.0f);
        } else {
            vertical_speed += gravity.Dot(up) * config->delta_seconds;
        }
        JPH::Vec3 desired = command
            ? JPH::Vec3(command->desired_velocity_x, command->desired_velocity_y, command->desired_velocity_z)
            : JPH::Vec3::sZero();
        desired -= up * desired.Dot(up);
        const JPH::Vec3 ground_velocity = grounded ? character.GetGroundVelocity() : JPH::Vec3::sZero();
        character.SetLinearVelocity(desired + up * vertical_speed + ground_velocity);

        JPH::CharacterVirtual::ExtendedUpdateSettings update_settings;
        update_settings.mWalkStairsStepUp = up * native.desc.step_height;
        update_settings.mStickToFloorStepDown = -up * std::max(native.desc.step_height, native.desc.skin_width);
        character.ExtendedUpdate(
            config->delta_seconds,
            gravity,
            update_settings,
            broadphase_filter,
            layer_filter,
            body_filter,
            {},
            *temp_allocator);

        if (written < state_capacity) {
            const JPH::RVec3 position = character.GetPosition();
            const JPH::Quat rotation = character.GetRotation();
            const JPH::Vec3 current_velocity = character.GetLinearVelocity();
            const JPH::Vec3 ground_normal = character.GetGroundNormal();
            const JPH::Vec3 current_ground_velocity = character.GetGroundVelocity();
            const uint64_t ground_entity = character.GetGroundUserData();
            uint8_t ground_state = 3;
            switch (character.GetGroundState()) {
            case JPH::CharacterBase::EGroundState::OnGround: ground_state = 0; break;
            case JPH::CharacterBase::EGroundState::OnSteepGround: ground_state = 1; break;
            case JPH::CharacterBase::EGroundState::NotSupported: ground_state = 2; break;
            case JPH::CharacterBase::EGroundState::InAir: ground_state = 3; break;
            }
            out_states[written++] = GuavaJoltCharacterState{
                entity,
                static_cast<float>(position.GetX()),
                static_cast<float>(position.GetY()),
                static_cast<float>(position.GetZ()),
                rotation.GetX(), rotation.GetY(), rotation.GetZ(), rotation.GetW(),
                current_velocity.GetX(), current_velocity.GetY(), current_velocity.GetZ(),
                ground_normal.GetX(), ground_normal.GetY(), ground_normal.GetZ(),
                current_ground_velocity.GetX(), current_ground_velocity.GetY(), current_ground_velocity.GetZ(),
                ground_entity,
                ground_entity != 0 ? uint8_t(1) : uint8_t(0),
                ground_state,
                native.stance,
                0
            };
        }
    }
    return written;
    }

