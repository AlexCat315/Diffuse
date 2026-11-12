//! Translation of
//! Editor/Sources/EditorUI/Panels/Inspector/InspectorJSONInput.swift.
//!
//! The authored property stays serialized JSON; the editing surface owns a
//! persistent buffer and materializes it only when JSON validation commits.

use cove_ui_compose::primitives::controls::fields::json_field::JsonField;
use cove_ui_compose::primitives::controls::fields::json_field_model::JsonFieldLabels;
use cove_ui_compose::primitives::text::text_buffer::TextBuffer;
use cove_ui_compose::scene_core::Binding;
use cove_ui_compose::{AnyView, Scope, View};

pub struct InspectorJSONInput {
    pub text: Binding<String>,
    pub min_height: f32,
    pub labels: JsonFieldLabels,
}

impl InspectorJSONInput {
    pub fn new(text: Binding<String>, min_height: f32, labels: JsonFieldLabels) -> Self {
        InspectorJSONInput {
            text,
            min_height,
            labels,
        }
    }
}

impl View for InspectorJSONInput {
    fn body(&self, scope: &Scope) -> AnyView {
        let document = scope.state(InspectorJSONDocument::new);
        let source = self.text.get();
        if source != document.get().serialized {
            document.update(move |document| document.synchronize(&source));
        }
        let outer_text = self.text.clone();
        let binding = Binding::new(
            move || document.get().buffer.clone(),
            move |next: TextBuffer| {
                document.update(move |document| document.accept(next));
                let serialized = document.get().serialized;
                outer_text.set(serialized);
            },
        );
        AnyView::new(
            JsonField::new(binding)
                .min_height(self.min_height)
                .labels(self.labels.clone()),
        )
    }
}

/// Swift's `InspectorJSONDocument`: the buffer being edited plus the last
/// committed serialization, so an external change replaces the buffer but a
/// typing session does not.
#[derive(Clone)]
pub struct InspectorJSONDocument {
    pub buffer: TextBuffer,
    pub serialized: String,
}

impl InspectorJSONDocument {
    pub fn new() -> Self {
        InspectorJSONDocument {
            buffer: TextBuffer::empty(),
            serialized: String::new(),
        }
    }

    pub fn synchronize(&mut self, source: &str) {
        if source == self.serialized {
            return;
        }
        self.serialized = source.to_string();
        self.buffer = TextBuffer::new(source);
    }

    pub fn accept(&mut self, next: TextBuffer) {
        self.serialized = next.string_value();
        self.buffer = next;
    }
}

impl Default for InspectorJSONDocument {
    fn default() -> Self {
        Self::new()
    }
}
