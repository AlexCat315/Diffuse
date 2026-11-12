//! `Editor/Sources/EditorUI/Toolbar/Contributed.swift`.
//!
//! Package commands placed on the title bar, one icon button each.

use std::path::PathBuf;
use std::rc::Rc;

use cove_ui_compose::core_exports::cove_imaging::BundleImageResource;
use cove_ui_compose::primitives::controls::{Button, ButtonIconSource};
use cove_ui_compose::theme::styles::buttons::ToggleButtonStyle;
use cove_ui_compose::theme::styles::buttons::button_style::ButtonStyleViewExt;
use cove_ui_compose::{AnyView, LayoutDebugExt, Row, Scope, TupleView, VerticalAlignment, View};
use diffuse_editor_core::contributions::workbench::placements::ContributedToolbarItem;

use crate::commands::command::EditorCommand;
use crate::resources_support::EditorAppResourceBundle;

pub struct PluginToolbar {
    pub items: Vec<ContributedToolbarItem>,
    pub on_command: Rc<dyn Fn(EditorCommand)>,
}

impl PluginToolbar {
    pub fn new(
        items: Vec<ContributedToolbarItem>,
        on_command: impl Fn(EditorCommand) + 'static,
    ) -> Self {
        PluginToolbar {
            items,
            on_command: Rc::new(on_command),
        }
    }
}

impl View for PluginToolbar {
    fn body(&self, _scope: &Scope) -> AnyView {
        let bundle = EditorAppResourceBundle::bundle().root();
        let buttons = self
            .items
            .iter()
            .map(|item| {
                let resource = BundleImageResource::svg(
                    item.icon.clone(),
                    bundle.to_path_buf(),
                    Some(PathBuf::from("ToolbarIcons")),
                );
                let command = self.on_command.clone();
                let plugin_id = item.command.plugin_id.clone();
                let name = item.command.name.clone();
                AnyView::new(
                    Button::icon(ButtonIconSource::resource(resource), 13.0, move || {
                        command(EditorCommand::Plugin {
                            plugin_id: plugin_id.clone(),
                            name: name.clone(),
                        })
                    })
                    .tooltip(item.command.title.clone())
                    .button_style(ToggleButtonStyle::new(0.0, 26.0))
                    .debug_name(&format!("editor-plugin-tool-{}", item.command.name)),
                )
            })
            .collect::<Vec<_>>();
        AnyView::new(
            Row::new(
                VerticalAlignment::Center,
                2.0,
                AnyView::new(TupleView::new(buttons)),
            )
            .debug_name("editor-plugin-toolbar"),
        )
    }
}
