//! `Editor/Sources/EditorUI/Panels/Shared/CommitOnBlurTextField.swift`.
//!
//! Text field that edits a local draft and writes the binding once, on blur or
//! Return — instead of per keystroke. Model-side normalization then applies at
//! commit time and can no longer rewrite the text mid-edit, and one edit
//! produces one undo transaction instead of one per keystroke.

use cove_ui_compose::primitives::text::text_buffer::TextBuffer;
use cove_ui_compose::primitives::text::text_field::{
    TextField, TextFieldDecoration, TextFieldEvents, TextFieldSize,
};
use cove_ui_compose::scene_core::Binding;
use cove_ui_compose::{AnyView, Scope, View};

pub struct CommitOnBlurTextField {
    /// Stable identity of the edited slot (e.g. entity + field id). Editing
    /// state is dropped when the identity changes, so switching the selected
    /// entity mid-edit can't commit one entity's draft onto another.
    pub identity: String,
    pub text: Binding<String>,
    pub size: TextFieldSize,
    pub mixed_value_label: Option<String>,
}

impl CommitOnBlurTextField {
    pub fn new(identity: impl Into<String>, text: Binding<String>) -> Self {
        CommitOnBlurTextField {
            identity: identity.into(),
            text,
            size: TextFieldSize::Regular,
            mixed_value_label: None,
        }
    }

    pub fn size(mut self, size: TextFieldSize) -> Self {
        self.size = size;
        self
    }

    pub fn mixed_value_label(mut self, label: impl Into<String>) -> Self {
        self.mixed_value_label = Some(label.into());
        self
    }
}

impl View for CommitOnBlurTextField {
    fn body(&self, scope: &Scope) -> AnyView {
        let draft_changed = scope.state(|| false);
        let draft = scope.state(TextBuffer::empty);
        let editing_identity = scope.state(|| None::<String>);

        let initial = TextBuffer::from(if self.mixed_value_label.is_none() {
            self.text.get()
        } else {
            String::new()
        });

        let get = {
            let identity = self.identity.clone();
            let initial = initial.clone();
            move || {
                if editing_identity.get().as_deref() == Some(identity.as_str()) {
                    draft.get()
                } else {
                    initial.clone()
                }
            }
        };
        let set = {
            let identity = self.identity.clone();
            move |next: TextBuffer| {
                // Self-arming: the first keystroke after a Return-commit (focus
                // retained, editing cleared) re-enters draft mode.
                if editing_identity.get().as_deref() != Some(identity.as_str()) {
                    editing_identity.set(Some(identity.clone()));
                }
                if !draft.get().has_same_contents(&next) {
                    draft.set(next);
                }
                draft_changed.set(true);
            }
        };
        let field_binding = Binding::new(get, set);

        let commit = {
            let text = self.text.clone();
            let identity = self.identity.clone();
            let mixed = self.mixed_value_label.is_some();
            move |ends_editing: bool| {
                if editing_identity.get().as_deref() != Some(identity.as_str()) {
                    return;
                }
                if ends_editing {
                    editing_identity.set(None);
                }
                if !draft_changed.get() {
                    return;
                }
                draft_changed.set(false);
                let next = draft.get().string_value();
                if mixed || text.get() != next {
                    text.set(next.clone());
                    if text.get() != next {
                        draft.set(TextBuffer::from(text.get()));
                    }
                }
            }
        };

        let submit = {
            let commit = commit.clone();
            move || commit(false)
        };
        let blur = {
            let commit = commit.clone();
            move || commit(true)
        };
        let focus = {
            let identity = self.identity.clone();
            let initial = initial.clone();
            move || {
                if !draft.get().has_same_contents(&initial) {
                    draft.set(initial.clone());
                }
                draft_changed.set(false);
                if editing_identity.get().as_deref() != Some(identity.as_str()) {
                    editing_identity.set(Some(identity.clone()));
                }
            }
        };

        let field = TextField::new(
            self.mixed_value_label.clone().unwrap_or_default(),
            field_binding,
        )
        .decoration(TextFieldDecoration {
            size: self.size,
            ..TextFieldDecoration::default()
        })
        .events(TextFieldEvents {
            on_submit: Some(std::rc::Rc::new(submit)),
            on_focus: Some(std::rc::Rc::new(focus)),
            on_blur: Some(std::rc::Rc::new(blur)),
            ..TextFieldEvents::default()
        });
        AnyView::new(field)
    }
}
