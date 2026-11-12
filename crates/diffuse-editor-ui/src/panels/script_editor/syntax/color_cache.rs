//! Translation of
//! Editor/Sources/EditorUI/Panels/ScriptEditor/Syntax/ColorCache.swift.

use std::collections::BTreeMap;

use super::syntax::SwiftSyntaxTokenKind;

/// A bounded cache for the current syntax snapshot, shared by source glyphs and
/// the minimap. Plain text positions are cached as well as coloured tokens.
#[derive(Clone, Debug)]
pub struct ScriptSyntaxColorCache {
    entries: BTreeMap<usize, Option<SwiftSyntaxTokenKind>>,
    capacity: usize,
}

impl ScriptSyntaxColorCache {
    pub fn new() -> Self {
        ScriptSyntaxColorCache {
            entries: BTreeMap::new(),
            capacity: 8_192,
        }
    }

    pub fn kind(
        &mut self,
        offset: usize,
        resolve: impl FnOnce() -> Option<SwiftSyntaxTokenKind>,
    ) -> Option<SwiftSyntaxTokenKind> {
        if let Some(entry) = self.entries.get(&offset) {
            return *entry;
        }
        let kind = resolve();
        if self.entries.len() >= self.capacity {
            self.entries.clear();
        }
        self.entries.insert(offset, kind);
        kind
    }

    pub fn invalidate(&mut self) {
        self.entries.clear();
    }
}

impl Default for ScriptSyntaxColorCache {
    fn default() -> Self {
        ScriptSyntaxColorCache::new()
    }
}
