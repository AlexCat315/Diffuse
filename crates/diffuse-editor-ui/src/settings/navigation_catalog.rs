//! `Editor/Sources/EditorUI/Settings/NavigationCatalog.swift`.

use cove_ui_compose::core_exports::cove_imaging::BundleImageResource;
use cove_ui_compose::primitives::media::ui_icon_catalog::{action, editor, file, status};

use crate::localization::localized;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum SettingsCategory {
    General,
    Editor,
    Assistant,
    Plugins,
    Shortcuts,
    About,
}

impl SettingsCategory {
    pub const ALL: [SettingsCategory; 6] = [
        SettingsCategory::General,
        SettingsCategory::Editor,
        SettingsCategory::Assistant,
        SettingsCategory::Plugins,
        SettingsCategory::Shortcuts,
        SettingsCategory::About,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            SettingsCategory::General => "general",
            SettingsCategory::Editor => "editor",
            SettingsCategory::Assistant => "assistant",
            SettingsCategory::Plugins => "plugins",
            SettingsCategory::Shortcuts => "shortcuts",
            SettingsCategory::About => "about",
        }
    }

    pub fn title(self) -> String {
        let key = match self {
            SettingsCategory::General => "General",
            SettingsCategory::Editor => "Editor",
            SettingsCategory::Assistant => "Assistant",
            SettingsCategory::Plugins => "Extensions",
            SettingsCategory::Shortcuts => "Keyboard Shortcuts",
            SettingsCategory::About => "About Cove",
        };
        localized(key)
    }

    pub fn summary(self) -> String {
        let key = match self {
            SettingsCategory::General => "Make this workspace feel like yours.",
            SettingsCategory::Editor => "Fine-tune how you work with the scene.",
            SettingsCategory::Assistant => {
                "Connect your model provider and choose how the assistant works with you."
            }
            SettingsCategory::Plugins => {
                "Manage built-in and added plugins and the access they get."
            }
            SettingsCategory::Shortcuts => "The shortcuts available in your current Space.",
            SettingsCategory::About => "Your workspace, application, and support information.",
        };
        localized(key)
    }

    pub fn icon(self) -> BundleImageResource {
        match self {
            SettingsCategory::General => action::settings(),
            SettingsCategory::Editor => editor::box_(),
            SettingsCategory::Assistant => status::sparkles(),
            SettingsCategory::Plugins => file::package(),
            SettingsCategory::Shortcuts => editor::code(),
            SettingsCategory::About => status::info(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum SettingsSectionID {
    Appearance,
    Language,
    Selection,
    Display,
    Swift,
    Provider,
    Execution,
    Capabilities,
    Plugins,
    Shortcuts,
    About,
}

impl SettingsSectionID {
    pub const ALL: [SettingsSectionID; 11] = [
        SettingsSectionID::Appearance,
        SettingsSectionID::Language,
        SettingsSectionID::Selection,
        SettingsSectionID::Display,
        SettingsSectionID::Swift,
        SettingsSectionID::Provider,
        SettingsSectionID::Execution,
        SettingsSectionID::Capabilities,
        SettingsSectionID::Plugins,
        SettingsSectionID::Shortcuts,
        SettingsSectionID::About,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            SettingsSectionID::Appearance => "appearance",
            SettingsSectionID::Language => "language",
            SettingsSectionID::Selection => "selection",
            SettingsSectionID::Display => "display",
            SettingsSectionID::Swift => "swift",
            SettingsSectionID::Provider => "provider",
            SettingsSectionID::Execution => "execution",
            SettingsSectionID::Capabilities => "capabilities",
            SettingsSectionID::Plugins => "plugins",
            SettingsSectionID::Shortcuts => "shortcuts",
            SettingsSectionID::About => "about",
        }
    }

    pub fn category(self) -> SettingsCategory {
        match self {
            SettingsSectionID::Appearance | SettingsSectionID::Language => {
                SettingsCategory::General
            }
            SettingsSectionID::Selection
            | SettingsSectionID::Display
            | SettingsSectionID::Swift => SettingsCategory::Editor,
            SettingsSectionID::Provider
            | SettingsSectionID::Execution
            | SettingsSectionID::Capabilities => SettingsCategory::Assistant,
            SettingsSectionID::Plugins => SettingsCategory::Plugins,
            SettingsSectionID::Shortcuts => SettingsCategory::Shortcuts,
            SettingsSectionID::About => SettingsCategory::About,
        }
    }

    pub fn title(self) -> String {
        let key = match self {
            SettingsSectionID::Appearance => "Appearance",
            SettingsSectionID::Language => "Language",
            SettingsSectionID::Selection => "Selection",
            SettingsSectionID::Display => "Display & Performance",
            SettingsSectionID::Swift => "Swift",
            SettingsSectionID::Provider => "Provider & Credentials",
            SettingsSectionID::Execution => "Execution & Review",
            SettingsSectionID::Capabilities => "Capability Gate",
            SettingsSectionID::Plugins => "Plugins",
            SettingsSectionID::Shortcuts => "Keyboard Shortcuts",
            SettingsSectionID::About => "Workspace Information",
        };
        localized(key)
    }

    fn keywords(self) -> &'static str {
        match self {
            SettingsSectionID::Appearance => {
                "appearance theme dark light color 外观 主题 深色 浅色 颜色"
            }
            SettingsSectionID::Language => {
                "language locale english chinese system 语言 中文 英文 系统"
            }
            SettingsSectionID::Selection => {
                "selection subtract toggle command control modifier 选择 减选 切换 修饰键"
            }
            SettingsSectionID::Display => {
                "display performance vertical sync vsync fps refresh 显示 性能 垂直 同步 刷新"
            }
            SettingsSectionID::Swift => {
                "swift format save formatting language service 格式化 保存 语言服务"
            }
            SettingsSectionID::Provider => {
                "assistant ai provider model api key credential anthropic openai deepseek 模型 密钥 凭据 服务商"
            }
            SettingsSectionID::Execution => {
                "assistant approval auto approve safe review 自动 确认 审阅 执行"
            }
            SettingsSectionID::Capabilities => {
                "capability gate stable beta experimental permissions 能力 稳定 测试 实验 权限"
            }
            SettingsSectionID::Plugins => {
                "plugin extension authorize revoke reload disable 插件 扩展 授权 撤销 重载 禁用"
            }
            SettingsSectionID::Shortcuts => "keyboard shortcut key binding 快捷键 键盘 按键",
            SettingsSectionID::About => {
                "about version project diagnostics support 关于 版本 项目 诊断 支持"
            }
        }
    }

    pub fn matches(self, query: &str) -> bool {
        let haystack = format!(
            "{} {} {}",
            self.category().title(),
            self.title(),
            self.keywords()
        )
        .to_lowercase();
        query
            .split_whitespace()
            .all(|token| haystack.contains(&token.to_lowercase()))
    }

    pub fn visible(
        category: SettingsCategory,
        query: &str,
        agent_enabled: bool,
    ) -> Vec<SettingsSectionID> {
        let query = query.trim();
        Self::ALL
            .into_iter()
            .filter(|section| agent_enabled || section.category() != SettingsCategory::Assistant)
            .filter(|section| {
                if query.is_empty() {
                    section.category() == category
                } else {
                    section.matches(query)
                }
            })
            .collect()
    }
}
