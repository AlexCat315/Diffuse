use super::{
    script_context::ScriptContext,
    script_definition::ScriptDefinition,
    script_lifecycle::{Script, ScriptCallback},
};
use std::sync::{Arc, Mutex};

pub trait ScriptBehavior: Default + Send + 'static {
    fn on_start(&mut self, context: &mut ScriptContext<'_, '_>) {
        let _ = context;
    }
    fn on_pre_physics(&mut self, context: &mut ScriptContext<'_, '_>) {
        let _ = context;
    }
    fn on_update(&mut self, context: &mut ScriptContext<'_, '_>) {
        let _ = context;
    }
    fn on_destroy(&mut self, context: &mut ScriptContext<'_, '_>) {
        let _ = context;
    }
}

pub trait ScriptAuthoring {
    fn definition() -> ScriptDefinition;
}

// All four lifecycle callbacks share the same mutable behavior, as in Swift.
struct ScriptBehaviorState<B: ScriptBehavior>(Mutex<B>);

impl<B: ScriptBehavior> ScriptBehaviorState<B> {
    fn with_behavior(&self, body: impl FnOnce(&mut B)) {
        let mut behavior = self.0.lock().unwrap_or_else(|error| error.into_inner());
        body(&mut behavior);
    }
}

impl Script {
    pub fn from_behavior<B: ScriptBehavior>() -> Self {
        let state = Arc::new(ScriptBehaviorState(Mutex::new(B::default())));
        let start = state.clone();
        let pre = state.clone();
        let update = state.clone();
        Self::new(
            Some(Arc::new(move |context| {
                start.with_behavior(|behavior| behavior.on_start(context))
            })),
            Some(Arc::new(move |context| {
                pre.with_behavior(|behavior| behavior.on_pre_physics(context))
            })),
            Some(Arc::new(move |context| {
                update.with_behavior(|behavior| behavior.on_update(context))
            })),
            Some(Arc::new(move |context| {
                state.with_behavior(|behavior| behavior.on_destroy(context))
            })),
        )
    }

    pub fn retaining<T: Send + Sync + 'static>(&self, lifetime: Arc<T>) -> Self {
        Self::new(
            retaining_callback(&self.on_start_handler, lifetime.clone()),
            retaining_callback(&self.on_pre_physics_handler, lifetime.clone()),
            retaining_callback(&self.on_tick_handler, lifetime.clone()),
            retaining_callback(&self.on_destroy_handler, lifetime),
        )
    }
}

fn retaining_callback<T: Send + Sync + 'static>(
    callback: &Option<ScriptCallback>,
    lifetime: Arc<T>,
) -> Option<ScriptCallback> {
    let callback = callback.clone()?;
    Some(Arc::new(move |context| {
        let _ = &lifetime;
        callback(context);
    }))
}
