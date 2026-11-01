use crate::{core::script_lifecycle::Script, presets::script_presets::ScriptVar};
use diffuse_math::simd::simd_compat::{
    Float3, Float4x4, Quatf, simd_clamp_scalar, simd_length_squared, simd_normalize,
};
use diffuse_scene::{rendering::render_extraction::CameraComponent, runtime_world::LocalTransform};
use std::sync::Arc;

impl Script {
    pub fn first_person_camera(move_speed: f32, look_sensitivity: f32) -> Self {
        Self::default().on_tick(Arc::new(move |context| {
            let input = context.input();
            let mut movement = Float3::new(input.axis("move_x"), 0.0, -input.axis("move_y"));
            if input.is_held("move_forward") {
                movement.z -= 1.0;
            }
            if input.is_held("move_back") {
                movement.z += 1.0;
            }
            if input.is_held("move_left") {
                movement.x -= 1.0;
            }
            if input.is_held("move_right") {
                movement.x += 1.0;
            }
            if input.is_held("move_up") {
                movement.y += 1.0;
            }
            if input.is_held("move_down") {
                movement.y -= 1.0;
            }
            if simd_length_squared(movement) > 0.0 {
                movement = simd_normalize(movement);
            }
            let speed = context.float_parameter("moveSpeed").unwrap_or(move_speed)
                * context.delta_time as f32;
            let sensitivity = context
                .float_parameter("lookSensitivity")
                .unwrap_or(look_sensitivity);
            let look_x = input.axis("look_x") * sensitivity;
            let look_y = input.axis("look_y") * sensitivity;
            if let Some(transform) = context.local_transform() {
                let yaw = Quatf::from_angle_axis(-look_x, Float3::new(0.0, 1.0, 0.0));
                let pitch = Quatf::from_angle_axis(-look_y, Float3::new(1.0, 0.0, 0.0));
                let rotation = yaw * transform.rotation() * pitch;
                let forward = rotation.act(Float3::new(0.0, 0.0, -1.0));
                let right = rotation.act(Float3::new(1.0, 0.0, 0.0));
                let up = Float3::new(0.0, 1.0, 0.0);
                let translation = transform.translation()
                    + forward * movement.z * speed
                    + right * movement.x * speed
                    + up * movement.y * speed;
                context.set_local_transform(
                    LocalTransform::new(Float4x4::from_quatf(rotation))
                        .with_translation(translation),
                );
            }
            if let Some(world) = context.world_transform()
                && context.has_component::<CameraComponent>()
            {
                let forward_column = world.matrix.columns[2].xyz();
                let up_column = world.matrix.columns[1].xyz();
                let forward = if simd_length_squared(forward_column) > 0.000_001 {
                    -simd_normalize(forward_column)
                } else {
                    Float3::new(0.0, 0.0, -1.0)
                };
                let up = if simd_length_squared(up_column) > 0.000_001 {
                    simd_normalize(up_column)
                } else {
                    Float3::new(0.0, 1.0, 0.0)
                };
                context.update_component::<CameraComponent>(|camera| {
                    camera.target = world.translation() + forward;
                    camera.up = up;
                });
            }
        }))
    }

    pub fn orbit_camera(
        target: Float3,
        distance: f32,
        orbit_speed: f32,
        zoom_speed: f32,
        min_distance: f32,
        max_distance: f32,
    ) -> Self {
        let yaw = ScriptVar::new(0.0_f32);
        let pitch = ScriptVar::new(std::f32::consts::PI / 6.0);
        let dist = ScriptVar::new(distance);
        let initialized = ScriptVar::new(false);
        Self::default().on_tick(Arc::new(move |context| {
            let input = context.input();
            if !initialized.get() {
                dist.set(context.float_parameter("distance").unwrap_or(distance));
                initialized.set(true);
            }
            let orbit_speed = context.float_parameter("orbitSpeed").unwrap_or(orbit_speed);
            let zoom_speed = context.float_parameter("zoomSpeed").unwrap_or(zoom_speed);
            let min_distance = context
                .float_parameter("minDistance")
                .unwrap_or(min_distance);
            let candidate_max = context
                .float_parameter("maxDistance")
                .unwrap_or(max_distance);
            let max_distance = if min_distance < candidate_max {
                candidate_max
            } else {
                min_distance
            };
            yaw.with_value(|yaw| *yaw -= input.axis("orbit_x") * orbit_speed);
            pitch.with_value(|pitch| {
                *pitch -= input.axis("orbit_y") * orbit_speed;
                *pitch = simd_clamp_scalar(
                    *pitch,
                    -std::f32::consts::PI / 2.0 + 0.01,
                    std::f32::consts::PI / 2.0 - 0.01,
                );
            });
            dist.with_value(|dist| {
                *dist -= input.axis("camera_zoom") * zoom_speed;
                *dist = simd_clamp_scalar(*dist, min_distance, max_distance);
            });
            let rotation = Quatf::from_angle_axis(yaw.get(), Float3::new(0.0, 1.0, 0.0))
                * Quatf::from_angle_axis(pitch.get(), Float3::new(1.0, 0.0, 0.0));
            let offset = rotation.act(Float3::new(0.0, 0.0, -dist.get()));
            let target = context.vector3_parameter("target").unwrap_or(target);
            context.set_local_transform(
                LocalTransform::new(Float4x4::from_quatf(rotation))
                    .with_translation(target + offset),
            );
            context.update_component::<CameraComponent>(|camera| {
                camera.target = target;
                camera.up = Float3::new(0.0, 1.0, 0.0);
            });
        }))
    }
}
