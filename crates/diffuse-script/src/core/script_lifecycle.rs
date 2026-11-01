use super::script_context::ScriptContext;
use std::sync::Arc;

pub type ScriptCallback =
    Arc<dyn for<'phase, 'world> Fn(&mut ScriptContext<'phase, 'world>) + Send + Sync>;

#[derive(Clone, Default)]
pub struct Script {
    pub(crate) on_start_handler: Option<ScriptCallback>,
    pub(crate) on_pre_physics_handler: Option<ScriptCallback>,
    pub(crate) on_tick_handler: Option<ScriptCallback>,
    pub(crate) on_destroy_handler: Option<ScriptCallback>,
}

impl Script {
    pub fn new(
        on_start: Option<ScriptCallback>,
        on_pre_physics: Option<ScriptCallback>,
        on_tick: Option<ScriptCallback>,
        on_destroy: Option<ScriptCallback>,
    ) -> Self {
        Self {
            on_start_handler: on_start,
            on_pre_physics_handler: on_pre_physics,
            on_tick_handler: on_tick,
            on_destroy_handler: on_destroy,
        }
    }
    pub fn on_start(&self, handler: ScriptCallback) -> Self {
        let mut script = self.clone();
        script.on_start_handler = Some(handler);
        script
    }
    pub fn on_tick(&self, handler: ScriptCallback) -> Self {
        let mut script = self.clone();
        script.on_tick_handler = Some(handler);
        script
    }
    pub fn on_pre_physics(&self, handler: ScriptCallback) -> Self {
        let mut script = self.clone();
        script.on_pre_physics_handler = Some(handler);
        script
    }
    pub fn on_update(&self, handler: ScriptCallback) -> Self {
        self.on_tick(handler)
    }
    pub fn on_destroy(&self, handler: ScriptCallback) -> Self {
        let mut script = self.clone();
        script.on_destroy_handler = Some(handler);
        script
    }
}
