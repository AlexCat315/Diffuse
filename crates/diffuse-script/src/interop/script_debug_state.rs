use crate::core::script_context::ScriptContext;
use diffuse_scene::entity_id::EntityID;
use std::collections::BTreeMap;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ScriptDebugState {
    pub entities: BTreeMap<EntityID, BTreeMap<String, String>>,
}
impl ScriptDebugState {
    pub fn new() -> Self {
        Self::default()
    }
}

impl ScriptContext<'_, '_> {
    pub fn report_state(&mut self, values: &BTreeMap<String, String>) {
        let mut state = self.resource::<ScriptDebugState>().unwrap_or_default();
        let mut reported = BTreeMap::new();
        for (key, value) in values.iter().take(32) {
            reported.insert(
                key.graphemes(true).take(128).collect(),
                value.graphemes(true).take(1024).collect(),
            );
        }
        state.entities.insert(self.entity, reported);
        self.set_resource(state);
    }
}
