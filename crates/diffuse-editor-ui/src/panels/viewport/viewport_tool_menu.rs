//! Translation of Editor/Sources/EditorUI/Panels/Viewport/ViewportToolMenu.swift.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::rc::Rc;

use cove_ui_compose::modifiers::interaction::AccessibilityExt;
use cove_ui_compose::primitives::overlays::{
    Menu, MenuEntry, MenuItem, Popover, PopoverOverflow, PopoverSurface,
};
use cove_ui_compose::scene_core::Binding;
use cove_ui_compose::{AnyView, LayoutDebugExt, Scope, View};
use diffuse_editor_core::state::editor_reducer::EditorAction;
use diffuse_editor_core::state::editor_state::EditorGizmoMode;
use diffuse_editor_core::state::editor_store::EditorStore;

use super::controls::{ViewportMenuTrigger, viewport_popover_dismiss_on_escape};
use crate::localization::localized;

pub struct ViewportToolMenu {
    pub store: Rc<EditorStore>,
    pub mode: EditorGizmoMode,
    pub is_enabled: bool,
}

struct Tool {
    mode: EditorGizmoMode,
    title: &'static str,
    key: &'static str,
}

const TOOLS: [Tool; 5] = [
    Tool {
        mode: EditorGizmoMode::None,
        title: "Pick",
        key: "Q",
    },
    Tool {
        mode: EditorGizmoMode::BoxSelect,
        title: "Box Select",
        key: "B",
    },
    Tool {
        mode: EditorGizmoMode::Translate,
        title: "Move",
        key: "W",
    },
    Tool {
        mode: EditorGizmoMode::Rotate,
        title: "Rotate",
        key: "E",
    },
    Tool {
        mode: EditorGizmoMode::Scale,
        title: "Scale",
        key: "R",
    },
];

impl ViewportToolMenu {
    pub fn new(store: Rc<EditorStore>, mode: EditorGizmoMode, is_enabled: bool) -> Self {
        ViewportToolMenu {
            store,
            mode,
            is_enabled,
        }
    }

    fn title(mode: EditorGizmoMode) -> String {
        let title = TOOLS
            .iter()
            .find(|tool| tool.mode == mode)
            .map(|tool| tool.title)
            .unwrap_or("Pick");
        localized(title)
    }

    fn entries(&self) -> Vec<MenuEntry> {
        TOOLS
            .iter()
            .map(|tool| {
                let store = self.store.clone();
                let mode = tool.mode;
                MenuEntry::Item(
                    MenuItem::new(
                        menu_item_id(&format!("viewport-tool-{}", tool.key.to_ascii_lowercase())),
                        localized(tool.title),
                        move || store.dispatch(EditorAction::SetGizmoMode(mode)),
                    )
                    .shortcut(tool.key)
                    .selected(self.mode == tool.mode),
                )
            })
            .collect()
    }
}

impl View for ViewportToolMenu {
    fn body(&self, scope: &Scope) -> AnyView {
        let is_presented = scope.state(|| false);
        let title = Self::title(self.mode);
        let trigger = AnyView::new(
            ViewportMenuTrigger::new(None, Some(title.clone()), false, false).accessibility(
                move |semantics| {
                    semantics.label = localized("Tool");
                    semantics.value = title.clone();
                },
            ),
        );
        let menu = Menu::new(self.entries())
            .width(200.0)
            .on_item_activated(move || is_presented.set(false));
        let binding = Binding::new(
            move || is_presented.get(),
            move |value| is_presented.set(value),
        );
        AnyView::new(
            Popover::new(trigger, menu)
                .is_presented(binding)
                .enabled(self.is_enabled)
                .width(200.0)
                .surface(PopoverSurface::Content)
                .overflow(PopoverOverflow::Flip)
                .on_key(viewport_popover_dismiss_on_escape(is_presented))
                .debug_name("viewport-tool-menu"),
        )
    }
}

/// Swift's string item identifiers keep the menu stable across rebuilds; Rust
/// menus key rows by integer, so the same identifier is hashed instead.
fn menu_item_id(identifier: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    identifier.hash(&mut hasher);
    hasher.finish()
}
