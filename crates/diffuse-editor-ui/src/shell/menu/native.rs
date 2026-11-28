//! `Editor/Sources/EditorUI/Shell/Menu/Native.swift`.

use std::rc::Rc;

use cove_platform::NativeApplicationMenuTitles;
use cove_ui::{NativeMenu, NativeMenuAction, NativeMenuBar, NativeMenuItem, NativeMenuKeyModifiers};

use crate::commands::catalog::{EditorCommandCatalog, EditorCommandEntry, EditorCommandItem};
use crate::commands::command::EditorCommand;
use crate::commands::dispatcher::EditorCommandDispatcher;
use crate::localization::localized;

type CommandHandler = Rc<dyn Fn(EditorCommand)>;
type CommandAvailability = Rc<dyn Fn(&EditorCommandEntry) -> bool>;

pub struct EditorNativeMenuBuilder;

impl EditorNativeMenuBuilder {
    pub fn make(app_name: &str, catalog: &EditorCommandCatalog, on_command: CommandHandler) -> NativeMenuBar {
        Self::make_with_availability(app_name, catalog, on_command, Rc::new(|entry| {
            EditorCommandDispatcher::is_enabled(&entry.command, entry.is_enabled)
        }))
    }

    pub fn make_with_availability(
        app_name: &str,
        catalog: &EditorCommandCatalog,
        on_command: CommandHandler,
        availability: CommandAvailability,
    ) -> NativeMenuBar {
        let application_items = native_items(&catalog.application_items, &on_command, &availability);
        let menus = catalog.menus.iter().filter_map(|menu| {
            let items = native_items(&menu.items, &on_command, &availability);
            (!items.is_empty()).then(|| NativeMenu::new(menu.title.clone(), items))
        }).collect();
        let mut bar = NativeMenuBar::new(app_name, application_items, menus);
        bar.application_titles = application_titles(app_name);
        bar
    }

    pub fn projectless(app_name: &str, on_open_folder: impl Fn() + 'static) -> NativeMenuBar {
        let shortcut = EditorCommandCatalog::open_folder_shortcut();
        let open = NativeMenuAction::new(localized("Open Folder..."), on_open_folder)
            .with_shortcut(shortcut.key.equivalent, shortcut.modifiers.native());
        let mut bar = NativeMenuBar::new(app_name, Vec::new(), vec![
            NativeMenu::new(localized("File"), vec![NativeMenuItem::Action(open)]),
        ]);
        bar.application_titles = application_titles(app_name);
        bar
    }
}

fn native_items(
    items: &[EditorCommandItem],
    on_command: &CommandHandler,
    availability: &CommandAvailability,
) -> Vec<NativeMenuItem> {
    let mut result = Vec::new();
    for item in items {
        match item {
            EditorCommandItem::Separator => {
                if result.last().is_some_and(|previous| !matches!(previous, NativeMenuItem::Separator)) {
                    result.push(NativeMenuItem::Separator);
                }
            }
            EditorCommandItem::Submenu(menu) => {
                let items = native_items(&menu.items, on_command, availability);
                if !items.is_empty() {
                    result.push(NativeMenuItem::Submenu(NativeMenu::new(menu.title.clone(), items)));
                }
            }
            EditorCommandItem::Entry(entry) => {
                let command = entry.command.clone();
                let action = {
                    let on_command = on_command.clone();
                    move || on_command(command.clone())
                };
                let mut action = NativeMenuAction::new(entry.title.clone(), action)
                    .with_selected(entry.is_selected).with_enabled_provider({
                        let availability = availability.clone();
                        let entry = entry.clone();
                        move || availability(&entry)
                    });
                action.is_enabled = entry.is_enabled;
                action = match &entry.shortcut {
                    Some(shortcut) => action.with_shortcut(shortcut.key.equivalent.clone(), shortcut.modifiers.native()),
                    None => action.with_shortcut("", NativeMenuKeyModifiers::default()),
                };
                result.push(NativeMenuItem::Action(action));
            }
        }
    }
    if matches!(result.last(), Some(NativeMenuItem::Separator)) {
        result.pop();
    }
    result
}

fn application_titles(app_name: &str) -> NativeApplicationMenuTitles {
    NativeApplicationMenuTitles {
        services: localized("Services"),
        hide: localized("Hide %@").replace("%@", app_name),
        hide_others: localized("Hide Others"),
        show_all: localized("Show All"),
        quit: localized("Quit %@").replace("%@", app_name),
    }
}
