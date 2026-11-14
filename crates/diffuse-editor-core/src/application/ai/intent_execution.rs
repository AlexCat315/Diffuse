//! `Editor/Sources/EditorCore/Application/AI/IntentExecution.swift` (selected helpers).
//!
//! The full IntentExecution extension also defines `submitSpawnEntityIntent`,
//! `submitResolvedIntent`, `makeCapabilityInvocationContext`,
//! `applyInvocationResult`, `makeExecutionContext` and friends; those are ported
//! incrementally alongside the AI request pipeline.

use diffuse_scene::entity_id::EntityID;

use crate::application::editor_application::EditorApplication;

impl EditorApplication {
    /// `entityID(from:)` — reconstructs an `EntityID` from its packed `UInt64`
    /// (`index` in the low 32 bits, `generation` in the high 32 bits).
    pub(crate) fn entity_id(&self, raw_id: Option<u64>) -> Option<EntityID> {
        raw_id.map(|raw| EntityID::new((raw & 0xFFFF_FFFF) as u32, (raw >> 32) as u32))
    }

    /// `prefix(_:bytes:)` — the longest UTF-8 prefix of `text` within `bytes`
    /// bytes that does not split a scalar.
    pub(crate) fn prefix(text: &str, bytes: usize) -> String {
        if text.len() <= bytes {
            return text.to_string();
        }
        let mut cut = bytes;
        while cut > 0 {
            if std::str::from_utf8(&text.as_bytes()[..cut]).is_ok() {
                return text[..cut].to_string();
            }
            cut -= 1;
        }
        String::new()
    }
}
