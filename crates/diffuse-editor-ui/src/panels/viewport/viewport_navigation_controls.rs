//! Translation of Editor/Sources/EditorUI/Panels/Viewport/ViewportNavigationControls.swift.

use std::rc::Rc;

use cove_ui_compose::modifiers::interaction::AccessibilityExt;
use cove_ui_compose::modifiers::layout::{FlexExt, LayoutFrameExt, PaddingExt};
use cove_ui_compose::modifiers::style::AppearanceExt;
use cove_ui_compose::primitives::controls::Button;
use cove_ui_compose::primitives::controls::fields::numeric::number_field::NumberField;
use cove_ui_compose::primitives::media::ui_icon_catalog;
use cove_ui_compose::primitives::overlays::{Popover, PopoverOverflow, PopoverSurface, Tooltip};
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::scene_core::Binding;
use cove_ui_compose::theme::styles::buttons::{ButtonStyleViewExt, ToggleButtonStyle};
use cove_ui_compose::theme::{SemanticColorRef, SemanticFontRef, SemanticStyleViewExt};
use cove_ui_compose::{
    AnyView, Column, HorizontalAlignment, LayoutDebugExt, Row, Scope, TupleView, VerticalAlignment,
    View,
};
use diffuse_editor_core::state::editor_reducer::EditorAction;
use diffuse_editor_core::state::editor_state::EditorGizmoSpace;
use diffuse_editor_core::state::editor_store::EditorStore;

use super::controls::{ViewportMenuTrigger, viewport_popover_dismiss_on_escape};
use crate::localization::localized;

pub struct ViewportTransformMenu {
    pub store: Rc<EditorStore>,
    pub is_enabled: bool,
}

impl ViewportTransformMenu {
    pub fn new(store: Rc<EditorStore>, is_enabled: bool) -> Self {
        ViewportTransformMenu { store, is_enabled }
    }

    fn space_label(space: EditorGizmoSpace) -> String {
        localized(match space {
            EditorGizmoSpace::Local => "Local",
            EditorGizmoSpace::World => "World",
        })
    }

    fn snap_row(&self, row: SnapRow, on_toggle: impl Fn() + 'static) -> AnyView {
        let toggle_label = AnyView::new(
            Text::new(localized(row.label))
                .semantic_font(SemanticFontRef::label())
                .semantic_foreground(SemanticColorRef::on_surface()),
        );
        let toggle = AnyView::new(
            Button::new(toggle_label, on_toggle)
                .selected(row.enabled)
                .enabled(self.is_enabled)
                .button_style(ToggleButtonStyle::default())
                .frame_size(54.0, 26.0)
                .debug_name(&format!("viewport-snap-{}-toggle", row.id)),
        );
        let mut field = NumberField::new(row.value)
            .enabled(self.is_enabled)
            .range(Some(0.001), Some(row.maximum));
        field.decimals = 3;
        let field = AnyView::new(
            field
                .frame_size(82.0, 26.0)
                .debug_name(&format!("viewport-snap-{}-step", row.id)),
        );
        let suffix = AnyView::new(
            Text::new(row.suffix)
                .line_limit(Some(1))
                .semantic_font(SemanticFontRef::caption())
                .semantic_foreground(SemanticColorRef::on_surface_muted()),
        );
        AnyView::new(Row::new(
            VerticalAlignment::Center,
            8.0,
            AnyView::new(TupleView::new(vec![toggle, field, suffix])),
        ))
    }
}

struct SnapRow {
    id: &'static str,
    label: &'static str,
    enabled: bool,
    value: Binding<f32>,
    maximum: f32,
    suffix: String,
}

impl View for ViewportTransformMenu {
    fn body(&self, scope: &Scope) -> AnyView {
        let is_presented = scope.state(|| false);
        let store = self.store.clone();
        let translate = store.translate_snap_enabled();
        let rotate = store.rotate_snap_enabled();
        let scale = store.scale_snap_enabled();
        let space = store.gizmo_space();
        let space_label = Self::space_label(space);

        let trigger = AnyView::new(
            Tooltip::new(
                ViewportMenuTrigger::new(
                    Some(ui_icon_catalog::action::sliders()),
                    None,
                    translate || rotate || scale,
                    false,
                ),
                Text::new(format!(
                    "{} · {space_label}",
                    localized("Transform Settings")
                )),
            )
            .accessibility({
                let space_label = space_label.clone();
                move |semantics| {
                    semantics.label = localized("Transform Settings");
                    semantics.value = space_label.clone();
                }
            }),
        );

        let local_button = {
            let store = store.clone();
            AnyView::new(
                Button::new(AnyView::new(Text::new(localized("Local"))), move || {
                    store.dispatch(EditorAction::SetGizmoSpace(EditorGizmoSpace::Local))
                })
                .selected(space == EditorGizmoSpace::Local)
                .button_style(ToggleButtonStyle::default())
                .flex_with(1.0, 1.0, None)
                .debug_name("viewport-space-local"),
            )
        };
        let world_button = {
            let store = store.clone();
            AnyView::new(
                Button::new(AnyView::new(Text::new(localized("World"))), move || {
                    store.dispatch(EditorAction::SetGizmoSpace(EditorGizmoSpace::World))
                })
                .selected(space == EditorGizmoSpace::World)
                .button_style(ToggleButtonStyle::default())
                .flex_with(1.0, 1.0, None)
                .debug_name("viewport-space-world"),
            )
        };
        let space_row = AnyView::new(Row::new(
            VerticalAlignment::Center,
            4.0,
            AnyView::new(TupleView::new(vec![local_button, world_button])),
        ));
        let heading = AnyView::new(
            Text::new(localized("Snap Steps"))
                .semantic_font(SemanticFontRef::caption())
                .semantic_foreground(SemanticColorRef::on_surface_muted()),
        );

        let translate_value = {
            let store = store.clone();
            let setter = store.clone();
            Binding::new(
                move || store.translate_snap_step(),
                move |value| setter.dispatch(EditorAction::SetTranslateSnapStep(value)),
            )
        };
        let rotate_value = {
            let store = store.clone();
            let setter = store.clone();
            Binding::new(
                move || store.rotate_snap_step_degrees(),
                move |value| setter.dispatch(EditorAction::SetRotateSnapStepDegrees(value)),
            )
        };
        let scale_value = {
            let store = store.clone();
            let setter = store.clone();
            Binding::new(
                move || store.scale_snap_step(),
                move |value| setter.dispatch(EditorAction::SetScaleSnapStep(value)),
            )
        };

        let translate_row = self.snap_row(
            SnapRow {
                id: "translate",
                label: "Move",
                enabled: translate,
                value: translate_value,
                maximum: 10_000.0,
                suffix: localized("World Units"),
            },
            {
                let store = store.clone();
                move || store.dispatch(EditorAction::SetTranslateSnapEnabled(!translate))
            },
        );
        let rotate_row = self.snap_row(
            SnapRow {
                id: "rotate",
                label: "Rotate",
                enabled: rotate,
                value: rotate_value,
                maximum: 180.0,
                suffix: "°".to_string(),
            },
            {
                let store = store.clone();
                move || store.dispatch(EditorAction::SetRotateSnapEnabled(!rotate))
            },
        );
        let scale_row = self.snap_row(
            SnapRow {
                id: "scale",
                label: "Scale",
                enabled: scale,
                value: scale_value,
                maximum: 10.0,
                suffix: localized("Scale Increment"),
            },
            {
                let store = store.clone();
                move || store.dispatch(EditorAction::SetScaleSnapEnabled(!scale))
            },
        );

        let content = AnyView::new(
            Column::new(
                HorizontalAlignment::Leading,
                8.0,
                AnyView::new(TupleView::new(vec![
                    space_row,
                    heading,
                    translate_row,
                    rotate_row,
                    scale_row,
                ])),
            )
            .padding(10.0)
            .semantic_background(SemanticColorRef::surface_floating())
            .corner_radius(10.0)
            .semantic_border(SemanticColorRef::divider(), 1.0),
        );

        let binding = Binding::new(
            move || is_presented.get(),
            move |value| is_presented.set(value),
        );
        AnyView::new(
            Popover::new(trigger, content)
                .is_presented(binding)
                .enabled(self.is_enabled)
                .width(280.0)
                .surface(PopoverSurface::Content)
                .overflow(PopoverOverflow::Flip)
                .on_key(viewport_popover_dismiss_on_escape(is_presented))
                .debug_name("viewport-transform-menu"),
        )
    }
}
