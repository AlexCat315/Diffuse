//! The component tree a plugin view returns.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/Workbench/Tree.rs`.
//! The host draws every node in its own style; the plugin only says what it is,
//! what it holds and which action it raises.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::contract::plugin_json::PluginJSON;
use crate::pattern::{icon, lower_component};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[derive(Default)]
pub enum Tone {
    #[default]
    Normal,
    Muted,
    Accent,
    Success,
    Warning,
    Danger,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[derive(Default)]
pub enum Align {
    Start,
    Center,
    End,
    #[default]
    Stretch,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[derive(Default)]
pub enum TextStyle {
    #[default]
    Body,
    Caption,
    Label,
    Strong,
    Mono,
    Title,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[derive(Default)]
pub enum ButtonStyle {
    Primary,
    #[default]
    Secondary,
    Ghost,
    Danger,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Background {
    Canvas,
    Surface,
    Raised,
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct Stack {
    pub children: Vec<UINode>,
    pub spacing: i64,
    pub padding: i64,
    pub align: Align,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Text {
    pub text: String,
    pub style: TextStyle,
    pub tone: Tone,
}

impl Default for Text {
    fn default() -> Self {
        Text {
            text: String::new(),
            style: TextStyle::Body,
            tone: Tone::Normal,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Button {
    pub title: Option<String>,
    pub icon: Option<String>,
    pub style: ButtonStyle,
    pub action: String,
    pub arguments: Option<PluginJSON>,
    pub disabled: bool,
    pub align: Align,
}

impl Default for Button {
    fn default() -> Self {
        Button {
            title: None,
            icon: None,
            style: ButtonStyle::Secondary,
            action: String::new(),
            arguments: None,
            disabled: false,
            align: Align::Center,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct TextField {
    pub id: String,
    pub placeholder: Option<String>,
    pub value: Option<String>,
    pub secure: bool,
    pub multiline: bool,
    /// Raised on Return.
    pub submit: Option<String>,
    /// Raised while typing, debounced by the host.
    pub change: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Toggle {
    pub id: String,
    pub label: Option<String>,
    pub value: bool,
    pub action: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SelectOption {
    pub value: String,
    pub label: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Select {
    pub id: String,
    pub options: Vec<SelectOption>,
    pub value: String,
    pub action: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Disclosure {
    pub title: String,
    pub expanded: bool,
    pub action: String,
    pub arguments: Option<PluginJSON>,
    pub children: Vec<UINode>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TableRow {
    pub cells: Vec<String>,
    pub action: Option<String>,
    pub arguments: Option<PluginJSON>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Table {
    pub columns: Vec<String>,
    pub rows: Vec<TableRow>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum UINodeKind {
    Column(Stack),
    Row(Stack),
    Scroll(Box<UINode>),
    Section {
        title: Option<String>,
        children: Vec<UINode>,
    },
    Spacer,
    Text(Text),
    Badge {
        text: String,
        tone: Tone,
    },
    Icon {
        name: String,
        tone: Tone,
    },
    Progress(Option<i64>),
    Button(Button),
    TextField(TextField),
    Toggle(Toggle),
    Select(Select),
    Disclosure(Disclosure),
    Table(Table),
}

/// One component of a plugin view.
#[derive(Clone, Debug, PartialEq)]
pub struct UINode {
    /// Keeps a component's identity, and its host-held state, across renders.
    pub key: Option<String>,
    pub flex: Option<i64>,
    pub width: Option<i64>,
    pub fill_width: Option<bool>,
    pub max_width: Option<i64>,
    pub min_height: Option<i64>,
    pub background: Option<Background>,
    pub corner_radius: Option<i64>,
    pub kind: UINodeKind,
}

impl UINode {
    pub fn new(kind: UINodeKind) -> Self {
        UINode {
            key: None,
            flex: None,
            width: None,
            fill_width: None,
            max_width: None,
            min_height: None,
            background: None,
            corner_radius: None,
            kind,
        }
    }

    pub const MAXIMUM_NODES: usize = 4_000;
    pub const MAXIMUM_DEPTH: usize = 24;
    pub const MAXIMUM_TEXT: usize = 4 * 1_024;
    pub const MAXIMUM_INPUT_BYTES: usize = 64 * 1_024;

    /// Whether the tree stays within the host's bounds and every name it uses is
    /// well formed.
    pub fn is_valid(&self) -> bool {
        let mut count = 0usize;
        let mut ids: BTreeSet<String> = BTreeSet::new();
        self.validate(1, &mut count, &mut ids)
    }

    fn validate(&self, depth: usize, count: &mut usize, ids: &mut BTreeSet<String>) -> bool {
        *count += 1;
        if !(depth <= Self::MAXIMUM_DEPTH
            && *count <= Self::MAXIMUM_NODES
            && self
                .key
                .as_ref()
                .is_none_or(|key| Self::is_text(key, false))
            && self.flex.is_none_or(|flex| (0..=100).contains(&flex))
            && self.width.is_none_or(|width| (1..=4096).contains(&width))
            && self
                .min_height
                .is_none_or(|height| (0..=4096).contains(&height))
            && self
                .corner_radius
                .is_none_or(|radius| (0..=32).contains(&radius))
            && self
                .max_width
                .is_none_or(|width| (1..=4096).contains(&width)))
        {
            return false;
        }
        let all = |nodes: &[UINode], count: &mut usize, ids: &mut BTreeSet<String>| {
            nodes
                .iter()
                .all(|node| node.validate(depth + 1, count, ids))
        };
        let claim =
            |id: &str, ids: &mut BTreeSet<String>| Self::is_name(id) && ids.insert(id.to_string());
        match &self.kind {
            UINodeKind::Column(stack) | UINodeKind::Row(stack) => {
                (0..=32).contains(&stack.spacing)
                    && (0..=32).contains(&stack.padding)
                    && all(&stack.children, count, ids)
            }
            UINodeKind::Scroll(child) => child.validate(depth + 1, count, ids),
            UINodeKind::Section { title, children } => {
                title
                    .as_ref()
                    .is_none_or(|title| Self::is_text(title, false))
                    && all(children, count, ids)
            }
            UINodeKind::Spacer => true,
            UINodeKind::Text(text) => Self::is_text(&text.text, true),
            UINodeKind::Badge { text, .. } => {
                Self::is_text(text, false) && text.chars().count() <= 32
            }
            UINodeKind::Icon { name, .. } => Self::is_icon(name),
            UINodeKind::Progress(percent) => percent.is_none_or(|value| (0..=100).contains(&value)),
            UINodeKind::Button(button) => {
                (button.title.is_some() || button.icon.is_some())
                    && button
                        .title
                        .as_ref()
                        .is_none_or(|title| Self::is_text(title, false))
                    && button.icon.as_ref().is_none_or(|icon| Self::is_icon(icon))
                    && Self::is_name(&button.action)
                    && Self::is_arguments(button.arguments.as_ref())
            }
            UINodeKind::TextField(field) => {
                claim(&field.id, ids)
                    && field
                        .placeholder
                        .as_ref()
                        .is_none_or(|placeholder| Self::is_text(placeholder, false))
                    && field
                        .value
                        .as_ref()
                        .is_none_or(|value| value.len() <= Self::MAXIMUM_INPUT_BYTES)
                    && field
                        .submit
                        .as_ref()
                        .is_none_or(|submit| Self::is_name(submit))
                    && field
                        .change
                        .as_ref()
                        .is_none_or(|change| Self::is_name(change))
            }
            UINodeKind::Toggle(toggle) => {
                claim(&toggle.id, ids)
                    && toggle
                        .label
                        .as_ref()
                        .is_none_or(|label| Self::is_text(label, false))
                    && toggle
                        .action
                        .as_ref()
                        .is_none_or(|action| Self::is_name(action))
            }
            UINodeKind::Select(select) => {
                claim(&select.id, ids)
                    && !select.options.is_empty()
                    && select.options.len() <= 256
                    && select.options.iter().all(|option| {
                        Self::is_text(&option.value, false) && Self::is_text(&option.label, false)
                    })
                    && select
                        .options
                        .iter()
                        .any(|option| option.value == select.value)
                    && select
                        .action
                        .as_ref()
                        .is_none_or(|action| Self::is_name(action))
            }
            UINodeKind::Disclosure(disclosure) => {
                Self::is_text(&disclosure.title, false)
                    && Self::is_name(&disclosure.action)
                    && Self::is_arguments(disclosure.arguments.as_ref())
                    && all(&disclosure.children, count, ids)
            }
            UINodeKind::Table(table) => {
                *count += table.rows.len();
                !table.columns.is_empty()
                    && table.columns.len() <= 16
                    && table
                        .columns
                        .iter()
                        .all(|column| Self::is_text(column, false))
                    && *count <= Self::MAXIMUM_NODES
                    && table.rows.iter().all(|row| {
                        row.cells.len() == table.columns.len()
                            && row.cells.iter().all(|cell| Self::is_text(cell, true))
                            && row
                                .action
                                .as_ref()
                                .is_none_or(|action| Self::is_name(action))
                            && Self::is_arguments(row.arguments.as_ref())
                    })
            }
        }
    }

    pub fn is_text(value: &str, allows_empty: bool) -> bool {
        (allows_empty || !value.is_empty()) && value.len() <= Self::MAXIMUM_TEXT
    }

    /// Component IDs and action names.
    pub fn is_name(value: &str) -> bool {
        lower_component(value, 1, 64)
    }

    pub fn is_icon(value: &str) -> bool {
        icon(value, 1, 64)
    }

    pub fn is_arguments(value: Option<&PluginJSON>) -> bool {
        let Some(value) = value else {
            return true;
        };
        if !matches!(value, PluginJSON::Object(_)) {
            return false;
        }
        serde_json::to_vec(value).is_ok_and(|data| data.len() <= 4 * 1_024)
    }
}

impl<'de> Deserialize<'de> for UINode {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        use serde::de::Error as _;
        #[derive(Deserialize, Clone)]
        struct RowCoding {
            cells: Vec<String>,
            #[serde(default)]
            action: Option<String>,
            #[serde(default)]
            arguments: Option<PluginJSON>,
        }
        #[derive(Deserialize, Clone)]
        struct Coding {
            #[serde(rename = "type")]
            kind: String,
            #[serde(default)]
            key: Option<String>,
            #[serde(default)]
            flex: Option<i64>,
            #[serde(default)]
            width: Option<i64>,
            #[serde(default, rename = "fillWidth")]
            fill_width: Option<bool>,
            #[serde(default, rename = "maxWidth")]
            max_width: Option<i64>,
            #[serde(default, rename = "minHeight")]
            min_height: Option<i64>,
            #[serde(default)]
            background: Option<Background>,
            #[serde(default, rename = "cornerRadius")]
            corner_radius: Option<i64>,
            #[serde(default)]
            children: Option<Vec<UINode>>,
            #[serde(default)]
            child: Option<Box<UINode>>,
            #[serde(default)]
            spacing: Option<i64>,
            #[serde(default)]
            padding: Option<i64>,
            #[serde(default)]
            align: Option<Align>,
            #[serde(default)]
            title: Option<String>,
            #[serde(default)]
            text: Option<String>,
            /// `"style"` names a `TextStyle` on a text node and a `ButtonStyle`
            /// on a button; one node carries one `type`, so the tag is read here
            /// and interpreted by the arm that needs it.
            #[serde(default)]
            style: Option<String>,
            #[serde(default)]
            tone: Option<Tone>,
            #[serde(default)]
            name: Option<String>,
            #[serde(default)]
            percent: Option<i64>,
            #[serde(default)]
            icon: Option<String>,
            #[serde(default)]
            action: Option<String>,
            #[serde(default)]
            arguments: Option<PluginJSON>,
            #[serde(default)]
            disabled: Option<bool>,
            #[serde(default)]
            id: Option<String>,
            #[serde(default)]
            placeholder: Option<String>,
            #[serde(default)]
            value: Option<PluginJSON>,
            #[serde(default)]
            secure: Option<bool>,
            #[serde(default)]
            submit: Option<String>,
            #[serde(default)]
            change: Option<String>,
            #[serde(default)]
            label: Option<String>,
            #[serde(default)]
            options: Option<Vec<SelectOptionCoding>>,
            #[serde(default)]
            expanded: Option<bool>,
            #[serde(default)]
            columns: Option<Vec<String>>,
            #[serde(default)]
            rows: Option<Vec<RowCoding>>,
            #[serde(default)]
            multiline: Option<bool>,
        }
        #[derive(Deserialize, Clone)]
        struct SelectOptionCoding {
            value: String,
            label: String,
        }

        // `TextStyle(rawValue:)` / `ButtonStyle(rawValue:)`: only the cases the
        // enum declares decode; anything else fails like a bad raw value.
        fn text_style(raw: Option<&str>) -> Result<TextStyle, serde_json::Error> {
            match raw {
                None => Ok(TextStyle::Body),
                Some("body") => Ok(TextStyle::Body),
                Some("caption") => Ok(TextStyle::Caption),
                Some("label") => Ok(TextStyle::Label),
                Some("strong") => Ok(TextStyle::Strong),
                Some("mono") => Ok(TextStyle::Mono),
                Some("title") => Ok(TextStyle::Title),
                Some(other) => Err(serde::de::Error::custom(format!(
                    "unknown text style '{other}'"
                ))),
            }
        }
        fn button_style_for(raw: Option<&str>) -> Result<ButtonStyle, serde_json::Error> {
            match raw {
                None => Ok(ButtonStyle::Secondary),
                Some("primary") => Ok(ButtonStyle::Primary),
                Some("secondary") => Ok(ButtonStyle::Secondary),
                Some("ghost") => Ok(ButtonStyle::Ghost),
                Some("danger") => Ok(ButtonStyle::Danger),
                Some(other) => Err(serde::de::Error::custom(format!(
                    "unknown button style '{other}'"
                ))),
            }
        }

        let coding = Coding::deserialize(deserializer)?;
        let stack = |coding: &Coding| Stack {
            children: coding.children.clone().unwrap_or_default(),
            spacing: coding.spacing.unwrap_or(0),
            padding: coding.padding.unwrap_or(0),
            align: coding.align.unwrap_or_default(),
        };
        let kind = match coding.kind.as_str() {
            "column" => UINodeKind::Column(stack(&coding)),
            "row" => UINodeKind::Row(stack(&coding)),
            "scroll" => UINodeKind::Scroll(
                coding
                    .child
                    .clone()
                    .ok_or_else(|| D::Error::missing_field("child"))?,
            ),
            "section" => UINodeKind::Section {
                title: coding.title.clone(),
                children: coding.children.clone().unwrap_or_default(),
            },
            "spacer" => UINodeKind::Spacer,
            "text" => UINodeKind::Text(Text {
                text: coding
                    .text
                    .clone()
                    .ok_or_else(|| D::Error::missing_field("text"))?,
                style: text_style(coding.style.as_deref()).map_err(D::Error::custom)?,
                tone: coding.tone.unwrap_or_default(),
            }),
            "badge" => UINodeKind::Badge {
                text: coding
                    .text
                    .clone()
                    .ok_or_else(|| D::Error::missing_field("text"))?,
                tone: coding.tone.unwrap_or_default(),
            },
            "icon" => UINodeKind::Icon {
                name: coding
                    .name
                    .clone()
                    .ok_or_else(|| D::Error::missing_field("name"))?,
                tone: coding.tone.unwrap_or_default(),
            },
            "progress" => UINodeKind::Progress(coding.percent),
            "button" => UINodeKind::Button(Button {
                title: coding.title.clone(),
                icon: coding.icon.clone(),
                style: button_style_for(coding.style.as_deref()).map_err(D::Error::custom)?,
                action: coding
                    .action
                    .clone()
                    .ok_or_else(|| D::Error::missing_field("action"))?,
                arguments: coding.arguments.clone(),
                disabled: coding.disabled.unwrap_or(false),
                align: coding.align.unwrap_or(Align::Center),
            }),
            "textField" => UINodeKind::TextField(TextField {
                id: coding
                    .id
                    .clone()
                    .ok_or_else(|| D::Error::missing_field("id"))?,
                placeholder: coding.placeholder.clone(),
                value: coding.value.as_ref().and_then(|value| match value {
                    PluginJSON::String(text) => Some(text.clone()),
                    _ => None,
                }),
                secure: coding.secure.unwrap_or(false),
                multiline: coding.multiline.unwrap_or(false),
                submit: coding.submit.clone(),
                change: coding.change.clone(),
            }),
            "toggle" => UINodeKind::Toggle(Toggle {
                id: coding
                    .id
                    .clone()
                    .ok_or_else(|| D::Error::missing_field("id"))?,
                label: coding.label.clone(),
                // Swift decoded `value` as a required `Bool`.
                value: match coding.value.as_ref() {
                    Some(PluginJSON::Bool(flag)) => *flag,
                    _ => return Err(D::Error::missing_field("value")),
                },
                action: coding.action.clone(),
            }),
            "select" => UINodeKind::Select(Select {
                id: coding
                    .id
                    .clone()
                    .ok_or_else(|| D::Error::missing_field("id"))?,
                options: coding
                    .options
                    .clone()
                    .ok_or_else(|| D::Error::missing_field("options"))?
                    .into_iter()
                    .map(|option| SelectOption {
                        value: option.value,
                        label: option.label,
                    })
                    .collect(),
                // Swift decoded `value` as a required `String`.
                value: match coding.value.as_ref() {
                    Some(PluginJSON::String(text)) => text.clone(),
                    _ => return Err(D::Error::missing_field("value")),
                },
                action: coding.action.clone(),
            }),
            "disclosure" => UINodeKind::Disclosure(Disclosure {
                title: coding
                    .title
                    .clone()
                    .ok_or_else(|| D::Error::missing_field("title"))?,
                // Swift decoded `expanded` as a required `Bool`.
                expanded: coding
                    .expanded
                    .ok_or_else(|| D::Error::missing_field("expanded"))?,
                action: coding
                    .action
                    .clone()
                    .ok_or_else(|| D::Error::missing_field("action"))?,
                arguments: coding.arguments.clone(),
                children: coding.children.clone().unwrap_or_default(),
            }),
            "table" => UINodeKind::Table(Table {
                columns: coding
                    .columns
                    .clone()
                    .ok_or_else(|| D::Error::missing_field("columns"))?,
                rows: coding
                    .rows
                    .clone()
                    .ok_or_else(|| D::Error::missing_field("rows"))?
                    .into_iter()
                    .map(|row| TableRow {
                        cells: row.cells,
                        action: row.action,
                        arguments: row.arguments,
                    })
                    .collect(),
            }),
            other => {
                return Err(D::Error::custom(format!("unknown component '{other}'")));
            }
        };
        Ok(UINode {
            key: coding.key,
            flex: coding.flex,
            width: coding.width,
            fill_width: coding.fill_width,
            max_width: coding.max_width,
            min_height: coding.min_height,
            background: coding.background,
            corner_radius: coding.corner_radius,
            kind,
        })
    }
}
