//! `Editor/Sources/EditorUI/Panels/Inspector/ComponentMenu.swift`.
//!
//! Reset and Remove live on the component card they act on, so the user never
//! has to pick the component again from a list.

use std::collections::BTreeSet;
use std::rc::Rc;

use cove_ui_compose::modifiers::interaction::AccessibilityExt;
use cove_ui_compose::prelude::LayoutFrameExt;
use cove_ui_compose::primitives::media::Icon;
use cove_ui_compose::primitives::media::ui_icon_catalog;
use cove_ui_compose::primitives::overlays::Popover;
use cove_ui_compose::primitives::overlays::menu::{Menu, MenuEntry, MenuItem, MenuItemRole};
use cove_ui_compose::theme::{SemanticColorRef, SemanticIconSize};
use cove_ui_compose::{AnyView, LayoutDebugExt, Scope, View};
use diffuse_editor_core::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use diffuse_editor_core::state::editor_reducer::EditorAction;
use diffuse_editor_core::state::editor_state::EditorConsoleSeverity;
use diffuse_editor_core::state::editor_store::EditorStore;

use crate::localization::localized;
use crate::panels::viewport::controls::viewport_popover_dismiss_on_escape;

pub struct InspectorComponentMenu {
    pub type_id: String,
    pub title: String,
    pub entity_ids: BTreeSet<u64>,
    pub scene: EditorSceneAdapter,
    pub store: Rc<EditorStore>,
}

impl View for InspectorComponentMenu {
    fn body(&self, _scope: &Scope) -> AnyView {
        let is_presented = _scope.state(|| false);
        let title = self.title.clone();
        let trigger = AnyView::new(
            Icon::semantic_with_ref(
                ui_icon_catalog::action::more_horizontal(),
                SemanticIconSize::small(),
                SemanticColorRef::on_surface_muted(),
            )
            .frame_size(24.0, 24.0)
            .accessibility({
                let title = title.clone();
                move |semantics| semantics.label = title.clone()
            }),
        );

        let reset = {
            let scene = self.scene.clone();
            let store = self.store.clone();
            let type_id = self.type_id.clone();
            let title = title.clone();
            let ids = self.entity_ids.clone();
            move || perform(true, &scene, &store, &type_id, &title, &ids)
        };
        let remove = {
            let scene = self.scene.clone();
            let store = self.store.clone();
            let type_id = self.type_id.clone();
            let title = title.clone();
            let ids = self.entity_ids.clone();
            move || perform(false, &scene, &store, &type_id, &title, &ids)
        };
        let menu = Menu::new(vec![
            MenuEntry::Item(MenuItem::new(1, localized("Reset Component"), reset)),
            MenuEntry::Item(
                MenuItem::new(2, localized("Remove Component"), remove)
                    .role(MenuItemRole::Destructive),
            ),
        ])
        .width(200.0)
        .on_item_activated(move || is_presented.set(false));
        let binding = cove_ui_compose::scene_core::Binding::new(
            move || is_presented.get(),
            move |value| is_presented.set(value),
        );
        AnyView::new(
            Popover::new(trigger, menu)
                .is_presented(binding)
                .width(200.0)
                .surface(cove_ui_compose::primitives::overlays::PopoverSurface::Content)
                .overflow(cove_ui_compose::primitives::overlays::PopoverOverflow::Flip)
                .on_key(viewport_popover_dismiss_on_escape(is_presented))
                .debug_name(&format!("inspector-component-menu-{}", self.type_id)),
        )
    }
}

fn perform(
    reset: bool,
    scene: &EditorSceneAdapter,
    store: &EditorStore,
    type_id: &str,
    title: &str,
    entity_ids: &BTreeSet<u64>,
) {
    let succeeded = if reset {
        scene.reset_component(type_id, entity_ids)
    } else {
        scene.remove_component_from_selection(type_id, entity_ids)
    };
    if succeeded {
        return;
    }
    store.dispatch(EditorAction::AppendConsoleMessage {
        message: if reset {
            localized("Could not reset component")
        } else {
            localized("Could not remove component")
        },
        severity: EditorConsoleSeverity::Error,
        detail: Some(title.to_string()),
        target: None,
        next_step: None,
    });
}
