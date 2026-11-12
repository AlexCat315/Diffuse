//! `Editor/Sources/EditorUI/Commands/Catalog.swift`.
//!
//! Everything a command's availability depends on, and the one command tree.
//! The macOS menu bar, the Windows/Linux title-bar menu, the command palette and
//! keyboard shortcuts are all projections of it.

use cove_platform::KeyEvent;
use diffuse_editor_core::contributions::workbench::contributed::{
    ContributedCommand, ContributedPanel, ContributedPanelContent, WorkbenchCatalog,
};
use diffuse_editor_core::state::editor_state::PlaybackState;
use diffuse_editor_core::state::workspace::content::EditorContent;
use diffuse_editor_core::tasks::results::TaskKind;

use crate::ai::surface::EditorStudioView;
use crate::commands::command::{EditorCommand, EditorPaletteScope, EditorPanelArea};
use crate::commands::policy::{
    EditorPlaybackCommandPolicy, EditorSceneAuthoringPolicy, EditorWorkspaceCommandPolicy,
};
use crate::commands::shortcut::{EditorKeyModifiers, EditorShortcut, EditorShortcutKey};
use crate::localization::localized;
use crate::projects::editor_launch_context;
use crate::root::root_view_factory::localized_panel_title;

/// Everything a command's availability depends on. The native menu rebuilds
/// only when this value changes.
#[derive(Clone, Debug, PartialEq)]
pub struct EditorCommandContext {
    pub content: EditorContent,
    pub playback_state: PlaybackState,
    pub can_undo: bool,
    pub can_redo: bool,
    pub has_selection: bool,
    /// The editor's selected text document, when one is open.
    pub document: Option<EditorCommandDocument>,
    /// Commands and panels of the enabled packages.
    pub workbench: WorkbenchCatalog,
    /// The panel that holds the agent conversation, while an agent is enabled.
    pub agent_panel_id: Option<String>,
}

impl EditorCommandContext {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        content: EditorContent,
        playback_state: PlaybackState,
        can_undo: bool,
        can_redo: bool,
        has_selection: bool,
        document: Option<EditorCommandDocument>,
        workbench: WorkbenchCatalog,
        agent_panel_id: Option<String>,
    ) -> Self {
        EditorCommandContext {
            content,
            playback_state,
            can_undo,
            can_redo,
            has_selection,
            document,
            workbench,
            agent_panel_id,
        }
    }

    /// Swift's `init(content:)` with every other argument at its default.
    pub fn with_defaults(content: EditorContent) -> Self {
        EditorCommandContext::new(
            content,
            PlaybackState::Stopped,
            false,
            false,
            false,
            None,
            WorkbenchCatalog::empty(),
            None,
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorCommandDocument {
    pub is_dirty: bool,
}

impl EditorCommandDocument {
    pub fn new(is_dirty: bool) -> Self {
        EditorCommandDocument { is_dirty }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct EditorCommandEntry {
    /// Stable identifier used by the palette and tests.
    pub id: String,
    pub title: String,
    pub keywords: String,
    pub shortcut: Option<EditorShortcut>,
    pub command: EditorCommand,
    pub is_enabled: bool,
    pub is_selected: bool,
    /// Entries that only open the palette itself stay out of its results.
    pub in_palette: bool,
}

impl EditorCommandEntry {
    pub fn new(id: impl Into<String>, title: impl Into<String>, command: EditorCommand) -> Self {
        EditorCommandEntry {
            id: id.into(),
            title: title.into(),
            keywords: String::new(),
            shortcut: None,
            command,
            is_enabled: true,
            is_selected: false,
            in_palette: true,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum EditorCommandItem {
    Entry(EditorCommandEntry),
    Submenu(EditorCommandMenu),
    Separator,
}

impl EditorCommandItem {
    pub fn entry(&self) -> Option<&EditorCommandEntry> {
        match self {
            EditorCommandItem::Entry(entry) => Some(entry),
            _ => None,
        }
    }

    fn entries(&self) -> Vec<&EditorCommandEntry> {
        match self {
            EditorCommandItem::Entry(entry) => vec![entry],
            EditorCommandItem::Submenu(menu) => menu.items.iter().flat_map(Self::entries).collect(),
            EditorCommandItem::Separator => Vec::new(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct EditorCommandMenu {
    pub id: String,
    pub title: String,
    pub items: Vec<EditorCommandItem>,
}

impl EditorCommandMenu {
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        items: Vec<EditorCommandItem>,
    ) -> Self {
        EditorCommandMenu {
            id: id.into(),
            title: title.into(),
            items,
        }
    }

    /// Drops commands the workspace does not authorize, then collapses empty
    /// submenus and redundant separators so no menu shows dead structure.
    fn filtered(&self, content: EditorContent) -> Option<Self> {
        let mut kept: Vec<EditorCommandItem> = Vec::new();
        for item in &self.items {
            match item {
                EditorCommandItem::Entry(entry) => {
                    if !EditorWorkspaceCommandPolicy::allows(&entry.command, content) {
                        continue;
                    }
                    kept.push(item.clone());
                }
                EditorCommandItem::Submenu(menu) => {
                    let Some(menu) = menu.filtered(content) else {
                        continue;
                    };
                    kept.push(EditorCommandItem::Submenu(menu));
                }
                EditorCommandItem::Separator => {
                    if kept.is_empty() {
                        continue;
                    }
                    if matches!(kept.last(), Some(EditorCommandItem::Separator)) {
                        continue;
                    }
                    kept.push(item.clone());
                }
            }
        }
        if matches!(kept.last(), Some(EditorCommandItem::Separator)) {
            kept.pop();
        }
        if kept.is_empty() {
            return None;
        }
        Some(EditorCommandMenu {
            id: self.id.clone(),
            title: self.title.clone(),
            items: kept,
        })
    }
}

/// The one command tree. The macOS menu bar, the Windows/Linux title-bar menu,
/// the command palette and keyboard shortcuts are all projections of it.
#[derive(Clone, Debug, PartialEq)]
pub struct EditorCommandCatalog {
    /// About and Settings. macOS places them in the application menu; other
    /// presentations fold them into Help and Edit.
    pub application_items: Vec<EditorCommandItem>,
    pub menus: Vec<EditorCommandMenu>,
    /// Package commands. They have no menu placement, so only the palette lists them.
    pub contributed: Vec<EditorCommandEntry>,
}

impl EditorCommandCatalog {
    /// ⌘O opens a scene, so folders take ⌘⇧O.
    pub fn open_folder_shortcut() -> EditorShortcut {
        EditorShortcut::with_modifiers(
            EditorShortcutKey::letter('o'),
            EditorKeyModifiers::primary() | EditorKeyModifiers::SHIFT,
        )
    }

    pub fn make(context: &EditorCommandContext) -> Self {
        let builder = Builder::new(context);
        EditorCommandCatalog {
            application_items: builder.application_items(),
            menus: builder
                .menus()
                .into_iter()
                .filter_map(|menu| menu.filtered(context.content))
                .collect(),
            contributed: builder.contributed(),
        }
    }

    /// Menus for a presentation without an application menu.
    pub fn menus_with_application_items(&self) -> Vec<EditorCommandMenu> {
        let about: Vec<EditorCommandItem> = self
            .application_items
            .iter()
            .filter(|item| item.entry().is_some_and(|entry| entry.command.is_about()))
            .cloned()
            .collect();
        let settings: Vec<EditorCommandItem> = self
            .application_items
            .iter()
            .filter(|item| item.entry().is_some_and(|entry| !entry.command.is_about()))
            .cloned()
            .collect();
        self.menus
            .iter()
            .cloned()
            .map(|mut menu| {
                match menu.id.as_str() {
                    "edit" if !settings.is_empty() => {
                        menu.items.push(EditorCommandItem::Separator);
                        menu.items.extend(settings.iter().cloned());
                    }
                    "help" if !about.is_empty() => {
                        menu.items.push(EditorCommandItem::Separator);
                        menu.items.extend(about.iter().cloned());
                    }
                    _ => {}
                }
                menu
            })
            .collect()
    }

    /// Every entry in menu order, including nested submenus.
    pub fn entries(&self) -> Vec<EditorCommandEntry> {
        let mut entries: Vec<EditorCommandEntry> = self
            .application_items
            .iter()
            .flat_map(EditorCommandItem::entries)
            .cloned()
            .collect();
        for menu in &self.menus {
            entries.extend(
                menu.items
                    .iter()
                    .flat_map(EditorCommandItem::entries)
                    .cloned(),
            );
        }
        entries.extend(self.contributed.iter().cloned());
        entries
    }

    pub fn entry(&self, event: &KeyEvent) -> Option<EditorCommandEntry> {
        self.entries().into_iter().find(|entry| {
            entry
                .shortcut
                .as_ref()
                .is_some_and(|shortcut| shortcut.matches(event))
        })
    }

    /// A chord that is unavailable only because the game is running. Bare keys
    /// such as Delete stay silent: during play they usually belong to the game.
    pub fn is_blocked_only_by_playback(
        entry: &EditorCommandEntry,
        context: &EditorCommandContext,
    ) -> bool {
        let has_modifiers = entry
            .shortcut
            .as_ref()
            .is_some_and(|shortcut| !shortcut.modifiers.is_empty());
        if context.playback_state == PlaybackState::Stopped || entry.is_enabled || !has_modifiers {
            return false;
        }
        let mut stopped = context.clone();
        stopped.playback_state = PlaybackState::Stopped;
        EditorCommandCatalog::make(&stopped)
            .entries()
            .iter()
            .any(|candidate| candidate.id == entry.id && candidate.is_enabled)
    }
}

struct Builder<'a> {
    context: &'a EditorCommandContext,
}

impl<'a> Builder<'a> {
    fn new(context: &'a EditorCommandContext) -> Self {
        Builder { context }
    }

    fn can_author_scene(&self) -> bool {
        EditorSceneAuthoringPolicy::can_edit_scene(self.context.playback_state)
    }

    fn application_items(&self) -> Vec<EditorCommandItem> {
        vec![
            self.entry("app.about", "About Cove", "", None, EditorCommand::About),
            self.entry(
                "preferences",
                "Settings...",
                "preferences settings 设置 偏好",
                Some(EditorShortcut::new(EditorShortcutKey::comma())),
                EditorCommand::OpenSettings,
            ),
        ]
    }

    fn menus(&self) -> Vec<EditorCommandMenu> {
        // The agent is a plugin. With it disabled its menu must not exist at
        // all — no title, no "Set up Assistant", no shortcut into a view that
        // has nothing behind it.
        let mut core = vec![
            self.file(),
            self.edit(),
            self.select(),
            self.world(),
            self.view(),
        ];
        if let Some(agent) = self.agent_menu() {
            core.push(agent);
        }
        core.extend([self.run(), self.window(), self.help()]);
        core.into_iter()
            .map(|menu| self.placing_contributions(menu))
            .collect()
    }

    /// Package commands no menu holds; the menus already feed the palette the rest.
    fn contributed(&self) -> Vec<EditorCommandEntry> {
        let placed: std::collections::BTreeSet<String> = self
            .context
            .workbench
            .menu_items
            .iter()
            .map(|item| item.command.id())
            .collect();
        self.context
            .workbench
            .commands
            .iter()
            .filter(|command| !placed.contains(&command.id()))
            .map(|command| self.plugin_entry(command))
            .collect()
    }

    /// Package commands a menu holds follow the host's items.
    fn placing_contributions(&self, menu: EditorCommandMenu) -> EditorCommandMenu {
        let items: Vec<_> = self
            .context
            .workbench
            .menu_items
            .iter()
            .filter(|item| item.menu == menu.id)
            .collect();
        if items.is_empty() {
            return menu;
        }
        let mut menu = menu;
        menu.items.push(EditorCommandItem::Separator);
        menu.items.extend(
            items
                .into_iter()
                .map(|item| EditorCommandItem::Entry(self.plugin_entry(&item.command))),
        );
        menu
    }

    fn plugin_entry(&self, command: &ContributedCommand) -> EditorCommandEntry {
        EditorCommandEntry {
            id: format!("plugin.{}", command.id()),
            title: command.title.clone(),
            keywords: command.keywords.clone(),
            shortcut: None,
            command: EditorCommand::Plugin {
                plugin_id: command.plugin_id.clone(),
                name: command.name.clone(),
            },
            is_enabled: true,
            is_selected: false,
            in_palette: command.shows_in_palette,
        }
    }

    fn file(&self) -> EditorCommandMenu {
        let can_author_scene = self.can_author_scene();
        self.menu(
            "file",
            "File",
            vec![
                self.entry(
                    "scene.new",
                    "New Scene",
                    "new scene 新建场景",
                    Some(EditorShortcut::new(EditorShortcutKey::letter('n'))),
                    EditorCommand::NewScene,
                )
                .with_enabled(can_author_scene),
                self.entry(
                    "scene.open",
                    "Open Scene...",
                    "open scene 打开场景",
                    Some(EditorShortcut::new(EditorShortcutKey::letter('o'))),
                    EditorCommand::OpenScene,
                )
                .with_enabled(can_author_scene),
                self.palette_entry(
                    "search.resources",
                    "Open Resource...",
                    "",
                    Some(EditorShortcut::new(EditorShortcutKey::letter('p'))),
                    EditorCommand::ShowCommandPalette(EditorPaletteScope::Resources),
                ),
                self.entry(
                    "scene.save",
                    "Save Scene",
                    "save scene 保存场景",
                    Some(EditorShortcut::new(EditorShortcutKey::letter('s'))),
                    EditorCommand::SaveScene,
                ),
                self.entry(
                    "document.save",
                    "Save",
                    "save file document 保存 文件",
                    Some(EditorShortcut::new(EditorShortcutKey::letter('s'))),
                    EditorCommand::SaveDocument,
                )
                .with_enabled(
                    self.context
                        .document
                        .as_ref()
                        .is_some_and(|document| document.is_dirty),
                ),
                self.entry(
                    "document.revert",
                    "Discard Changes",
                    "revert discard reload 放弃修改 还原",
                    None,
                    EditorCommand::RevertDocument,
                )
                .with_enabled(
                    self.context
                        .document
                        .as_ref()
                        .is_some_and(|document| document.is_dirty),
                ),
                self.entry(
                    "document.close",
                    "Close File",
                    "close file 关闭文件",
                    Some(EditorShortcut::new(EditorShortcutKey::letter('w'))),
                    EditorCommand::CloseDocument,
                )
                .with_enabled(
                    self.context
                        .document
                        .as_ref()
                        .is_some_and(|document| !document.is_dirty),
                ),
                EditorCommandItem::Separator,
                self.entry(
                    "assets.import",
                    "Import Assets...",
                    "import assets 导入资源",
                    None,
                    EditorCommand::ImportAssets,
                )
                .with_enabled(can_author_scene),
                EditorCommandItem::Separator,
                self.entry(
                    "project.open",
                    "Open Folder...",
                    "open folder project 打开 文件夹 项目",
                    Some(EditorCommandCatalog::open_folder_shortcut()),
                    EditorCommand::OpenFolder,
                )
                .with_enabled(editor_launch_context::has_current()),
                self.entry(
                    "project.close",
                    "Close Project",
                    "close project 关闭项目",
                    None,
                    EditorCommand::CloseProject,
                ),
            ],
        )
    }

    fn edit(&self) -> EditorCommandMenu {
        let can_author_scene = self.can_author_scene();
        self.menu(
            "edit",
            "Edit",
            vec![
                self.entry(
                    "edit.undo",
                    "Undo",
                    "undo 撤销",
                    Some(EditorShortcut::new(EditorShortcutKey::letter('z'))),
                    EditorCommand::Undo,
                )
                .with_enabled(can_author_scene && self.context.can_undo),
                self.entry(
                    "edit.redo",
                    "Redo",
                    "redo 重做",
                    Some(EditorShortcut::with_modifiers(
                        EditorShortcutKey::letter('z'),
                        EditorKeyModifiers::primary() | EditorKeyModifiers::SHIFT,
                    )),
                    EditorCommand::Redo,
                )
                .with_enabled(can_author_scene && self.context.can_redo),
                EditorCommandItem::Separator,
                self.entry(
                    "edit.duplicate",
                    "Duplicate Selection",
                    "duplicate 复制",
                    Some(EditorShortcut::new(EditorShortcutKey::letter('d'))),
                    EditorCommand::DuplicateSelection,
                )
                .with_enabled(can_author_scene && self.context.has_selection),
                self.entry(
                    "edit.delete",
                    "Delete Selection",
                    "delete 删除",
                    Some(EditorShortcut::with_modifiers(
                        EditorShortcutKey::delete(),
                        EditorKeyModifiers::default(),
                    )),
                    EditorCommand::DeleteSelection,
                )
                .with_enabled(can_author_scene && self.context.has_selection),
            ],
        )
    }

    fn select(&self) -> EditorCommandMenu {
        let can_select = self.can_author_scene();
        self.menu(
            "select",
            "Select",
            vec![
                self.entry(
                    "select.all",
                    "Select All",
                    "select all entities 全选",
                    None,
                    EditorCommand::SelectAll,
                )
                .with_enabled(can_select),
                self.entry(
                    "select.none",
                    "Deselect",
                    "clear selection 取消选择",
                    None,
                    EditorCommand::ClearSelection,
                )
                .with_enabled(self.context.has_selection),
                self.entry(
                    "select.invert",
                    "Invert Selection",
                    "invert selection 反选",
                    None,
                    EditorCommand::InvertSelection,
                )
                .with_enabled(can_select),
                EditorCommandItem::Separator,
                self.entry(
                    "select.descendants",
                    "Select Descendants",
                    "children descendants 子级",
                    None,
                    EditorCommand::SelectDescendants,
                )
                .with_enabled(self.context.has_selection),
            ],
        )
    }

    fn world(&self) -> EditorCommandMenu {
        let can_author_scene = self.can_author_scene();
        let can_edit = can_author_scene && self.context.has_selection;
        let templates: Vec<EditorCommandItem> =
            diffuse_editor_core::scene::adapter::spawn::EditorEntityTemplate::ALL
                .into_iter()
                .map(|template| {
                    self.entry(
                        format!("world.add.{}", template.raw_value()),
                        template.display_name(),
                        "add create entity 添加 创建 实体",
                        None,
                        EditorCommand::SpawnEntity(template),
                    )
                    .with_enabled(can_author_scene)
                })
                .collect();
        let geometry: Vec<EditorCommandItem> =
            diffuse_editor_core::geometry::editor_geometry_authoring::EditorGeometryPreset::ALL
                .into_iter()
                .map(|preset| {
                    self.entry(
                        format!("world.geometry.{}", preset.raw_value()),
                        preset.display_name(),
                        &format!(
                            "{} mesh curve geometry modeling 建模 几何 曲线",
                            preset.display_name()
                        ),
                        None,
                        EditorCommand::CreateGeometry(preset),
                    )
                    .with_enabled(can_author_scene)
                })
                .collect();
        self.menu(
            "world",
            "World",
            vec![
                EditorCommandItem::Submenu(self.menu("add-entity", "Add Entity", templates)),
                EditorCommandItem::Submenu(self.menu("add-geometry", "Add Geometry", geometry)),
                EditorCommandItem::Separator,
                self.entry(
                    "world.frame",
                    "Frame Selected",
                    "frame focus 聚焦",
                    None,
                    EditorCommand::FrameSelection,
                )
                .with_enabled(self.context.has_selection),
                self.entry(
                    "world.visibility",
                    "Toggle Visibility",
                    "hide show 隐藏 显示",
                    None,
                    EditorCommand::ToggleSelectionVisibility,
                )
                .with_enabled(can_edit),
                self.entry(
                    "world.lock",
                    "Toggle Lock",
                    "lock unlock 锁定 解锁",
                    None,
                    EditorCommand::ToggleSelectionLock,
                )
                .with_enabled(can_edit),
                EditorCommandItem::Separator,
                self.entry(
                    "scene.settings",
                    "Scene Settings",
                    "physics scene 场景物理设置",
                    None,
                    EditorCommand::ShowSceneSettings,
                ),
            ],
        )
    }

    fn view(&self) -> EditorCommandMenu {
        let contents: Vec<EditorCommandItem> = EditorContent::ALL
            .into_iter()
            .enumerate()
            .map(|(index, content)| {
                self.entry(
                    format!("content.{}", content.raw_value()),
                    content.title(),
                    "show content 内容 场景 文件 时间线",
                    Some(EditorShortcut::new(EditorShortcutKey::digit(
                        index as i64 + 1,
                    ))),
                    EditorCommand::ShowContent(content),
                )
                .with_selected(self.context.content == content)
            })
            .collect();
        let surfaces: Vec<EditorCommandItem> = self
            .context
            .workbench
            .panels
            .iter()
            .filter_map(|panel| {
                let surface = panel.surface.as_ref()?;
                let id = format!("{}.{}", panel.plugin_id, surface);
                Some(self.entry(
                    format!("surface.{id}"),
                    &panel.title,
                    "view 视图",
                    None,
                    EditorCommand::ShowView(EditorStudioView::new(id)),
                ))
            })
            .collect();
        let mut items = contents;
        items.extend(surfaces);
        items.extend([
            EditorCommandItem::Separator,
            EditorCommandItem::Submenu(self.menu(
                "layout",
                "Layout",
                vec![
                    self.entry(
                        "layout.save",
                        "Save Layout",
                        "layout workspace 保存布局",
                        None,
                        EditorCommand::SaveLayout,
                    ),
                    self.entry(
                        "layout.reset",
                        "Reset Layout",
                        "layout workspace 重置布局",
                        Some(EditorShortcut::new(EditorShortcutKey::digit(0))),
                        EditorCommand::ResetLayout,
                    ),
                ],
            )),
            EditorCommandItem::Submenu(self.menu(
                "panels",
                "Panels",
                vec![
                    self.entry(
                        "area.leading",
                        "Toggle Left Sidebar",
                        "sidebar left panel hide show 左侧栏 侧边栏 显示 隐藏",
                        Some(EditorShortcut::with_modifiers(
                            EditorShortcutKey::letter('l'),
                            EditorKeyModifiers::primary() | EditorKeyModifiers::OPTION,
                        )),
                        EditorCommand::TogglePanelArea(EditorPanelArea::Leading),
                    ),
                    self.entry(
                        "area.trailing",
                        "Toggle Right Sidebar",
                        "sidebar right panel hide show 右侧栏 侧边栏 显示 隐藏",
                        Some(EditorShortcut::with_modifiers(
                            EditorShortcutKey::letter('r'),
                            EditorKeyModifiers::primary() | EditorKeyModifiers::OPTION,
                        )),
                        EditorCommand::TogglePanelArea(EditorPanelArea::Trailing),
                    ),
                    self.entry(
                        "area.bottom",
                        "Toggle Bottom Panel",
                        "bottom panel console hide show 底部面板 控制台 显示 隐藏",
                        Some(EditorShortcut::new(EditorShortcutKey::letter('j'))),
                        EditorCommand::TogglePanelArea(EditorPanelArea::Bottom),
                    ),
                ],
            )),
            EditorCommandItem::Separator,
            self.entry(
                "layout.viewport",
                "Maximize Viewport",
                "maximize 最大化视口",
                None,
                EditorCommand::MaximizePanel("viewport".to_string()),
            ),
            self.entry(
                "layout.documents",
                "Maximize Editor",
                "maximize code script 最大化编辑器 脚本",
                None,
                EditorCommand::MaximizePanel("documents".to_string()),
            ),
            self.entry(
                "layout.restore",
                "Restore Panels",
                "maximize restore 恢复面板",
                None,
                EditorCommand::RestorePanels,
            ),
            EditorCommandItem::Separator,
            self.palette_entry(
                "palette.commands",
                "Command Palette",
                "",
                Some(EditorShortcut::with_modifiers(
                    EditorShortcutKey::letter('p'),
                    EditorKeyModifiers::primary() | EditorKeyModifiers::SHIFT,
                )),
                EditorCommand::ShowCommandPalette(EditorPaletteScope::Commands),
            ),
            self.entry(
                "theme.toggle",
                "Toggle Theme",
                "dark light theme 主题",
                None,
                EditorCommand::ToggleTheme,
            ),
        ]);
        self.menu("view", "View", items)
    }

    /// `None` while no agent plugin is enabled: the editor contributes no agent
    /// menu of its own.
    fn agent_menu(&self) -> Option<EditorCommandMenu> {
        // Pending reviews sit at the top of the Agent thread, so one entry serves both.
        self.context.agent_panel_id.as_ref()?;
        Some(self.menu(
            "agent",
            "Agent",
            vec![
                self.palette_entry(
                    "agent.intent",
                    "Ask Cove...",
                    "",
                    Some(EditorShortcut::new(EditorShortcutKey::letter('k'))),
                    EditorCommand::FocusAssistant,
                ),
                self.entry(
                    "agent.show",
                    "Agent",
                    "agent assistant conversation review approval 智能体 对话 审阅",
                    None,
                    EditorCommand::ShowView(EditorStudioView::agent()),
                ),
                self.entry(
                    "view.toggle",
                    "Switch Workbench and Agent",
                    "workbench agent view switch 工作台 智能体 视图 切换",
                    Some(EditorShortcut::new(EditorShortcutKey::backslash())),
                    EditorCommand::ToggleView,
                ),
            ],
        ))
    }

    fn run(&self) -> EditorCommandMenu {
        let state = self.context.playback_state;
        let transport = |target: PlaybackState,
                         title: &str,
                         shortcut: Option<EditorShortcut>|
         -> EditorCommandItem {
            self.entry(
                format!("playback.{}", target.raw_value()),
                title,
                "game preview 游戏试玩",
                shortcut,
                EditorCommand::SetPlaybackState(target),
            )
            .with_enabled(EditorPlaybackCommandPolicy::can_transition(state, target))
            .with_selected(state == target)
        };
        self.menu(
            "run",
            "Run",
            vec![
                self.entry(
                    "playback.toggle",
                    "Play / Pause",
                    "play pause game 试玩 暂停",
                    Some(EditorShortcut::new(EditorShortcutKey::enter())),
                    EditorCommand::TogglePlayback,
                ),
                transport(PlaybackState::Playing, "Play", None),
                transport(PlaybackState::Paused, "Pause", None),
                transport(
                    PlaybackState::Stopped,
                    "Stop",
                    Some(EditorShortcut::with_modifiers(
                        EditorShortcutKey::enter(),
                        EditorKeyModifiers::primary() | EditorKeyModifiers::SHIFT,
                    )),
                ),
                EditorCommandItem::Separator,
                self.entry(
                    "project.build",
                    "Build Project",
                    "export build 导出构建",
                    Some(EditorShortcut::new(EditorShortcutKey::letter('b'))),
                    EditorCommand::BuildProject,
                ),
                self.entry(
                    "project.run",
                    "Build and Run",
                    "export run 构建运行",
                    Some(EditorShortcut::new(EditorShortcutKey::letter('r'))),
                    EditorCommand::BuildAndRun,
                ),
                EditorCommandItem::Separator,
                self.entry(
                    "task.build",
                    "Run Build Task",
                    "task build compile swift package 任务 构建 编译",
                    None,
                    EditorCommand::RunTask(TaskKind::Build),
                ),
                self.entry(
                    "task.test",
                    "Run Tests",
                    "task test xctest testing 任务 测试",
                    Some(EditorShortcut::new(EditorShortcutKey::letter('u'))),
                    EditorCommand::RunTask(TaskKind::Test),
                ),
            ],
        )
    }

    fn window(&self) -> EditorCommandMenu {
        let panel = |id: &str, keywords: &str, command: EditorCommand| {
            self.panel_entry(
                format!("panel.{id}"),
                id,
                format!("panel 面板 {keywords}"),
                command,
            )
        };
        let mut items = vec![
            panel(
                "hierarchy",
                "hierarchy outline 大纲 层级",
                EditorCommand::ShowPanel("hierarchy".to_string()),
            ),
            panel(
                "files",
                "files explorer 文件",
                EditorCommand::ShowPanel("files".to_string()),
            ),
            self.panel_entry(
                "inspector.show",
                "inspector",
                "inspector properties 属性".to_string(),
                EditorCommand::ShowPanel("inspector".to_string()),
            ),
            panel(
                "viewport",
                "viewport scene 场景 视口",
                EditorCommand::ShowPanel("viewport".to_string()),
            ),
            panel(
                "documents",
                "documents text code script 文档 代码 脚本",
                EditorCommand::ShowPanel("documents".to_string()),
            ),
            panel(
                "media",
                "video timeline 视频 时间线",
                EditorCommand::ShowPanel("media".to_string()),
            ),
            self.entry(
                "assets.show",
                "Content Browser",
                "assets 资源浏览器",
                None,
                EditorCommand::ShowAssets,
            ),
            EditorCommandItem::Separator,
            panel(
                "console",
                "console log 控制台 日志",
                EditorCommand::ShowPanel("console".to_string()),
            ),
            panel(
                "terminal",
                "terminal shell command line 终端 命令行",
                EditorCommand::ShowPanel("terminal".to_string()),
            ),
            self.entry(
                "problems.show",
                "Problems",
                "errors diagnostics 问题诊断错误",
                None,
                EditorCommand::ShowProblems,
            ),
            panel(
                "animation",
                "animation 动画",
                EditorCommand::ShowPanel("animation".to_string()),
            ),
            panel(
                "render-pipeline",
                "render 渲染",
                EditorCommand::ShowPanel("render-pipeline".to_string()),
            ),
            panel(
                "developer-tools",
                "profiler debugger 开发者工具",
                EditorCommand::ShowPanel("developer-tools".to_string()),
            ),
            EditorCommandItem::Separator,
        ];
        items.extend(self.contributed_panels());
        items.push(self.entry(
            "layout.reopen",
            "Reopen Closed Panel",
            "reopen 恢复关闭面板",
            Some(EditorShortcut::with_modifiers(
                EditorShortcutKey::letter('t'),
                EditorKeyModifiers::primary() | EditorKeyModifiers::SHIFT,
            )),
            EditorCommand::ReopenClosedPanel,
        ));
        self.menu("window", "Window", items)
    }

    /// Panels packages describe. A panel showing a host view, such as the agent
    /// conversation, has its own entry elsewhere.
    fn contributed_panels(&self) -> Vec<EditorCommandItem> {
        let panels: Vec<EditorCommandItem> = self
            .context
            .workbench
            .panels
            .iter()
            .filter(|panel| {
                panel.content == ContributedPanelContent::Model
                    && panel.surface.is_none()
                    && panel.in_surface.is_none()
            })
            .map(|panel: &ContributedPanel| {
                EditorCommandItem::Entry(EditorCommandEntry {
                    id: format!("panel.{}", panel.id),
                    title: panel.title.clone(),
                    keywords: "panel 面板".to_string(),
                    shortcut: None,
                    command: EditorCommand::ShowPanel(panel.id.clone()),
                    is_enabled: true,
                    is_selected: false,
                    in_palette: true,
                })
            })
            .collect();
        if panels.is_empty() {
            return Vec::new();
        }
        let mut items = panels;
        items.push(EditorCommandItem::Separator);
        items
    }

    fn help(&self) -> EditorCommandMenu {
        self.menu(
            "help",
            "Help",
            vec![self.entry(
                "help.documentation",
                "Documentation",
                "docs help 文档 帮助",
                None,
                EditorCommand::OpenDocumentation,
            )],
        )
    }

    fn menu(&self, id: &str, title: &str, items: Vec<EditorCommandItem>) -> EditorCommandMenu {
        EditorCommandMenu::new(id, localized(title), items)
    }

    /// Panel commands reuse the tab title so menus and tabs never disagree.
    fn panel_entry(
        &self,
        id: impl Into<String>,
        panel: &str,
        keywords: String,
        command: EditorCommand,
    ) -> EditorCommandItem {
        EditorCommandItem::Entry(EditorCommandEntry {
            id: id.into(),
            title: localized_panel_title(panel),
            keywords,
            shortcut: None,
            command,
            is_enabled: true,
            is_selected: false,
            in_palette: true,
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn entry(
        &self,
        id: impl Into<String>,
        title: &str,
        keywords: &str,
        shortcut: Option<EditorShortcut>,
        command: EditorCommand,
    ) -> EditorCommandItem {
        EditorCommandItem::Entry(EditorCommandEntry {
            id: id.into(),
            title: localized(title),
            keywords: keywords.to_string(),
            shortcut,
            command,
            is_enabled: true,
            is_selected: false,
            in_palette: true,
        })
    }

    fn palette_entry(
        &self,
        id: impl Into<String>,
        title: &str,
        keywords: &str,
        shortcut: Option<EditorShortcut>,
        command: EditorCommand,
    ) -> EditorCommandItem {
        match self.entry(id, title, keywords, shortcut, command) {
            EditorCommandItem::Entry(mut entry) => {
                entry.in_palette = false;
                EditorCommandItem::Entry(entry)
            }
            item => item,
        }
    }
}

impl EditorCommandItem {
    fn with_enabled(self, enabled: bool) -> Self {
        match self {
            EditorCommandItem::Entry(mut entry) => {
                entry.is_enabled = enabled;
                EditorCommandItem::Entry(entry)
            }
            item => item,
        }
    }

    fn with_selected(self, selected: bool) -> Self {
        match self {
            EditorCommandItem::Entry(mut entry) => {
                entry.is_selected = selected;
                EditorCommandItem::Entry(entry)
            }
            item => item,
        }
    }
}
