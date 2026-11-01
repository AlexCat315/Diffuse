use crate::core::{script_context::ScriptContext, script_lifecycle::Script};
use diffuse_math::simd::simd_compat::{Float3, Quatf, simd_length, simd_normalize};
use diffuse_scene::{entity_id::EntityID, runtime_world::LocalTransform};
use std::sync::{Arc, Mutex};

/// Captured variables retain Swift's shared reference semantics across script copies.
#[derive(Debug)]
pub struct ScriptVar<T>(Arc<Mutex<T>>);

impl<T> Clone for ScriptVar<T> {
    fn clone(&self) -> Self {
        Self(self.0.clone())
    }
}
impl<T> ScriptVar<T> {
    pub fn new(value: T) -> Self {
        Self(Arc::new(Mutex::new(value)))
    }
    pub fn with_value<R>(&self, body: impl FnOnce(&mut T) -> R) -> R {
        body(&mut self.0.lock().unwrap_or_else(|error| error.into_inner()))
    }
    pub fn set(&self, value: T) {
        self.with_value(|current| *current = value);
    }
}
impl<T: Clone> ScriptVar<T> {
    pub fn get(&self) -> T {
        self.with_value(|value| value.clone())
    }
}

impl Script {
    pub fn rotator(speed: Float3) -> Self {
        Self::default().on_tick(Arc::new(move |context| {
            let delta =
                context.vector3_parameter("speed").unwrap_or(speed) * context.delta_time as f32;
            let qx = Quatf::from_angle_axis(delta.x, Float3::new(1.0, 0.0, 0.0));
            let qy = Quatf::from_angle_axis(delta.y, Float3::new(0.0, 1.0, 0.0));
            let qz = Quatf::from_angle_axis(delta.z, Float3::new(0.0, 0.0, 1.0));
            let delta_q = qy * qx * qz;
            context.update_component::<LocalTransform>(|transform| {
                *transform = transform.with_rotation(delta_q * transform.rotation())
            });
        }))
    }

    pub fn oscillator(axis: Float3, amplitude: f32, frequency: f32) -> Self {
        let elapsed = ScriptVar::new(0.0_f32);
        let base = ScriptVar::new(None::<Float3>);
        Self::default().on_tick(Arc::new(move |context| {
            let elapsed = elapsed.with_value(|elapsed| {
                *elapsed += context.delta_time as f32;
                *elapsed
            });
            if base.get().is_none() {
                base.set(Some(
                    context
                        .local_transform()
                        .map(|transform| transform.translation())
                        .unwrap_or(Float3::ZERO),
                ));
            }
            let Some(base) = base.get() else {
                return;
            };
            let axis = context.vector3_parameter("axis").unwrap_or(axis);
            let amplitude = context.float_parameter("amplitude").unwrap_or(amplitude);
            let frequency = context.float_parameter("frequency").unwrap_or(frequency);
            let offset =
                axis * ((elapsed * frequency * std::f32::consts::PI * 2.0).sin() * amplitude);
            context.set_local_transform(LocalTransform::from_translation(base + offset));
        }))
    }

    pub fn follower(target: EntityID, speed: f32, arrival_radius: f32) -> Self {
        Self::default().on_tick(Arc::new(move |context| {
            let Some(target) = resolved_target(context, target) else {
                return;
            };
            let Some(target_world) = context.world_transform_of(target) else {
                return;
            };
            let Some(world) = context.world_transform() else {
                return;
            };
            let to_target = target_world.translation() - world.translation();
            let distance = simd_length(to_target);
            let radius = context
                .float_parameter("arrivalRadius")
                .unwrap_or(arrival_radius);
            if !(distance > radius) {
                return;
            }
            let speed = context.float_parameter("speed").unwrap_or(speed);
            let requested = speed * context.delta_time as f32;
            let step = if distance < requested {
                distance
            } else {
                requested
            };
            context.translate(simd_normalize(to_target) * step);
        }))
    }

    pub fn look_at_target(target: EntityID, forward: Float3) -> Self {
        Self::default().on_tick(Arc::new(move |context| {
            let Some(target) = resolved_target(context, target) else {
                return;
            };
            let Some(target_world) = context.world_transform_of(target) else {
                return;
            };
            let Some(world) = context.world_transform() else {
                return;
            };
            let direction = simd_normalize(target_world.translation() - world.translation());
            if !(simd_length(direction) > 1e-6) {
                return;
            }
            let rotation = Quatf::from_to(forward, direction);
            context.update_component::<LocalTransform>(|transform| {
                *transform = transform.with_rotation(rotation)
            });
        }))
    }

    pub fn destroy_after(seconds: f64) -> Self {
        let elapsed = ScriptVar::new(0.0_f64);
        Self::default().on_tick(Arc::new(move |context| {
            let elapsed = elapsed.with_value(|elapsed| {
                *elapsed += context.delta_time;
                *elapsed
            });
            if elapsed >= context.double_parameter("seconds").unwrap_or(seconds) {
                context.destroy_self();
            }
        }))
    }

    pub fn mover(velocity: Float3) -> Self {
        Self::default().on_tick(Arc::new(move |context| {
            let velocity = context.vector3_parameter("velocity").unwrap_or(velocity);
            context.translate(velocity * context.delta_time as f32);
        }))
    }
}

fn resolved_target(context: &mut ScriptContext<'_, '_>, target: EntityID) -> Option<EntityID> {
    if let Some(entity) = context.entity_parameter("targetEntityID") {
        return Some(entity);
    }
    if let Some(name) = context
        .string_parameter("targetEntityName")
        .map(str::to_owned)
        && let Some(entity) = context.entity_named(&name)
    {
        return Some(entity);
    }
    context.contains(target).then_some(target)
}
