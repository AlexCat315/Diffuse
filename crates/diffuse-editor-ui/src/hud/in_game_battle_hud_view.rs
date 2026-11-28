//! `Editor/Sources/EditorUI/HUD/InGameBattleHUDView.swift`.

use std::rc::Rc;

use cove_ui_compose::modifiers::layout::{FlexExt, LayoutFrameExt, PaddingExt};
use cove_ui_compose::modifiers::style::AppearanceExt;
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::scene_core::{Align, Color, FlexDirection, Justify, Wrap};
use cove_ui_compose::theme::{SemanticFontRef, SemanticStyleViewExt};
use cove_ui_compose::{
    AnyView, BoxView, DynamicField, EmptyView, Observed, Scope, Spacer, TupleView, View,
};
use diffuse_card_battle::support::battle_hud_snapshot::{
    BattleHUDSnapshot, BattleHandCardViewModel, BattleSkillViewModel,
};

use super::battle_hud_model::BattleHUDModel;

pub struct InGameBattleHUDView {
    snapshot: Observed<BattleHUDModel, BattleHUDSnapshot>,
}

impl InGameBattleHUDView {
    pub fn new(model: Rc<BattleHUDModel>) -> Self {
        Self {
            snapshot: Observed::new(model, BattleHUDModel::snapshot),
        }
    }
}

impl View for InGameBattleHUDView {
    fn body(&self, _scope: &Scope) -> AnyView {
        let snapshot = self.snapshot.get();
        let player = column(
            Align::Stretch,
            10.0,
            vec![hand(&snapshot), status_row(&snapshot)],
        );
        AnyView::new(
            layout(
                FlexDirection::Column,
                Align::Center,
                Justify::SpaceBetween,
                0.0,
                vec![
                    opponent_bar(&snapshot),
                    AnyView::new(Spacer::default()),
                    player,
                ],
            )
            .flex(1.0)
            .padding_edges(20.0, 16.0),
        )
    }

    fn dynamic_properties(&self) -> Vec<DynamicField> {
        vec![self.snapshot.dynamic_field("snapshot")]
    }
}

fn opponent_bar(snapshot: &BattleHUDSnapshot) -> AnyView {
    AnyView::new(
        column(
            Align::Center,
            4.0,
            vec![
                text(
                    "Opponent",
                    SemanticFontRef::label(),
                    rgba(0.8, 0.8, 0.85, 0.9),
                ),
                health_bar(
                    snapshot.opponent_health,
                    snapshot.opponent_max_health,
                    rgba(0.88, 0.28, 0.28, 1.0),
                    220.0,
                    8.0,
                ),
                text(
                    format!(
                        "{} / {}",
                        snapshot.opponent_health, snapshot.opponent_max_health
                    ),
                    SemanticFontRef::caption(),
                    rgba(0.7, 0.7, 0.75, 0.85),
                ),
            ],
        )
        .padding_edges(14.0, 10.0)
        .background_color(rgba(0.06, 0.07, 0.10, 0.78))
        .corner_radius(10.0),
    )
}

fn hand(snapshot: &BattleHUDSnapshot) -> AnyView {
    row(
        Align::FlexEnd,
        10.0,
        snapshot.hand.iter().map(hand_card).collect(),
    )
}

fn hand_card(card: &BattleHandCardViewModel) -> AnyView {
    let playable = card.is_playable;
    let green = rgba(0.35, 0.85, 0.55, 1.0);
    let effect_color = if card.damage > 0 {
        rgba(0.95, 0.55, 0.25, 1.0)
    } else {
        green
    };
    let badge = layout(
        FlexDirection::Row,
        Align::Center,
        Justify::Center,
        0.0,
        vec![text(
            card.cost.to_string(),
            SemanticFontRef::body_strong(),
            Color::WHITE,
        )],
    )
    .frame_size(22.0, 22.0)
    .background_color(if playable {
        rgba(0.35, 0.50, 0.95, 1.0)
    } else {
        rgba(0.25, 0.27, 0.33, 1.0)
    })
    .corner_radius(9999.0);
    let header = row(
        Align::Center,
        4.0,
        vec![
            AnyView::new(badge),
            AnyView::new(Spacer::default()),
            text(effect_label(card), SemanticFontRef::label(), effect_color),
        ],
    );
    AnyView::new(
        column(
            Align::Stretch,
            6.0,
            vec![
                header,
                AnyView::new(Spacer::default()),
                text(
                    card.title.clone(),
                    SemanticFontRef::body_strong(),
                    if playable {
                        rgba(0.95, 0.95, 0.98, 1.0)
                    } else {
                        rgba(0.55, 0.55, 0.60, 1.0)
                    },
                ),
                text(
                    if playable { "Playable" } else { "Need energy" },
                    SemanticFontRef::caption(),
                    if playable {
                        green
                    } else {
                        rgba(0.50, 0.50, 0.55, 0.8)
                    },
                ),
            ],
        )
        .padding(10.0)
        .frame_size(110.0, 156.0)
        .background_color(if playable {
            rgba(0.12, 0.15, 0.22, 0.92)
        } else {
            rgba(0.08, 0.09, 0.13, 0.85)
        })
        .corner_radius(8.0)
        .border_color(
            if playable {
                rgba(0.40, 0.55, 0.95, 0.85)
            } else {
                rgba(0.20, 0.22, 0.28, 0.6)
            },
            1.0,
        ),
    )
}

fn effect_label(card: &BattleHandCardViewModel) -> String {
    if card.damage > 0 {
        format!("ATK {}", card.damage)
    } else if card.healing > 0 {
        format!("HEL {}", card.healing)
    } else if card.block > 0 {
        format!("BLK {}", card.block)
    } else {
        "TACTIC".to_owned()
    }
}

fn status_row(snapshot: &BattleHUDSnapshot) -> AnyView {
    let skills = row(
        Align::Center,
        8.0,
        snapshot.skills.iter().map(skill_status).collect(),
    );
    let end_turn = layout(
        FlexDirection::Column,
        Align::Center,
        Justify::Center,
        0.0,
        vec![text(
            "END TURN",
            SemanticFontRef::body_strong(),
            rgba(0.95, 0.95, 1.0, 1.0),
        )],
    )
    .frame_size(80.0, 48.0)
    .background_color(rgba(0.22, 0.35, 0.70, 0.92))
    .corner_radius(10.0)
    .border_color(rgba(0.40, 0.55, 0.95, 0.70), 1.0);
    AnyView::new(
        row(
            Align::Center,
            12.0,
            vec![
                player_stats(snapshot),
                AnyView::new(Spacer::default()),
                skills,
                AnyView::new(Spacer::default()),
                AnyView::new(end_turn),
            ],
        )
        .padding_edges(14.0, 10.0)
        .background_color(rgba(0.06, 0.07, 0.10, 0.80))
        .corner_radius(10.0),
    )
}

fn player_stats(snapshot: &BattleHUDSnapshot) -> AnyView {
    let caption = rgba(0.75, 0.75, 0.80, 1.0);
    let label = |name| {
        AnyView::new(
            text(name, SemanticFontRef::label(), rgba(0.6, 0.6, 0.65, 1.0)).frame_width(30.0),
        )
    };
    let energy = row(
        Align::Center,
        4.0,
        (0..snapshot.max_energy)
            .map(|index| {
                let fill = if index < snapshot.energy {
                    rgba(0.40, 0.70, 0.98, 1.0)
                } else {
                    rgba(0.20, 0.22, 0.28, 1.0)
                };
                AnyView::new(
                    column(Align::Center, 0.0, Vec::new())
                        .frame_size(12.0, 12.0)
                        .background_color(fill)
                        .corner_radius(9999.0),
                )
            })
            .collect(),
    );
    column(
        Align::FlexStart,
        6.0,
        vec![
            row(
                Align::Center,
                8.0,
                vec![
                    label("HP"),
                    health_bar(
                        snapshot.health,
                        snapshot.max_health,
                        rgba(0.25, 0.80, 0.45, 1.0),
                        140.0,
                        6.0,
                    ),
                    text(
                        format!("{}/{}", snapshot.health, snapshot.max_health),
                        SemanticFontRef::caption(),
                        caption,
                    ),
                ],
            ),
            row(
                Align::Center,
                8.0,
                vec![
                    label("EP"),
                    energy,
                    text(
                        format!("{}/{}", snapshot.energy, snapshot.max_energy),
                        SemanticFontRef::caption(),
                        caption,
                    ),
                ],
            ),
        ],
    )
}

fn skill_status(skill: &BattleSkillViewModel) -> AnyView {
    let ready = skill.is_enabled;
    let marker = column(Align::Center, 0.0, Vec::new())
        .frame_size(36.0, 36.0)
        .background_color(if ready {
            rgba(0.28, 0.40, 0.75, 0.90)
        } else {
            rgba(0.15, 0.16, 0.20, 0.80)
        })
        .corner_radius(8.0)
        .border_color(
            if ready {
                rgba(0.40, 0.55, 0.95, 0.70)
            } else {
                rgba(0.22, 0.24, 0.30, 0.50)
            },
            1.0,
        );
    column(
        Align::Center,
        3.0,
        vec![
            AnyView::new(marker),
            text(
                if ready {
                    "Ready".to_owned()
                } else {
                    format!("CD {}", skill.cooldown_turns)
                },
                SemanticFontRef::caption(),
                if ready {
                    rgba(0.65, 0.80, 1.0, 1.0)
                } else {
                    rgba(0.45, 0.45, 0.50, 1.0)
                },
            ),
            text(
                skill.title.clone(),
                SemanticFontRef::label(),
                rgba(0.70, 0.70, 0.75, 0.9),
            ),
        ],
    )
}

fn health_bar(current: i64, maximum: i64, fill: Color, width: f32, height: f32) -> AnyView {
    let maximum = maximum.max(0);
    let current = current.clamp(0, maximum);
    let remaining = if maximum == 0 { 1 } else { maximum - current };
    let segment = |length, color| {
        AnyView::new(
            column(Align::Stretch, 0.0, Vec::new())
                .flex(length)
                .background_color(color),
        )
    };
    AnyView::new(
        row(
            Align::Stretch,
            0.0,
            vec![
                segment(current as f32, fill),
                segment(remaining as f32, rgba(0.18, 0.20, 0.25, 0.85)),
            ],
        )
        .frame_size(width, height)
        .corner_radius(9999.0)
        .clipped(),
    )
}

fn text(value: impl Into<String>, font: SemanticFontRef, color: Color) -> AnyView {
    AnyView::new(
        Text::new(value.into())
            .semantic_font(font)
            .foreground_color(color),
    )
}

fn row(align: Align, spacing: f32, children: Vec<AnyView>) -> AnyView {
    layout(
        FlexDirection::Row,
        align,
        Justify::FlexStart,
        spacing,
        children,
    )
}

fn column(align: Align, spacing: f32, children: Vec<AnyView>) -> AnyView {
    layout(
        FlexDirection::Column,
        align,
        Justify::FlexStart,
        spacing,
        children,
    )
}

fn layout(
    direction: FlexDirection,
    align: Align,
    justify: Justify,
    spacing: f32,
    children: Vec<AnyView>,
) -> AnyView {
    let content = if children.is_empty() {
        AnyView::new(EmptyView)
    } else {
        AnyView::new(TupleView::new(children))
    };
    AnyView::new(BoxView::new(
        direction,
        align,
        justify,
        Wrap::NoWrap,
        spacing,
        content,
    ))
}

fn rgba(r: f32, g: f32, b: f32, a: f32) -> Color {
    Color { r, g, b, a }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use cove_ui_compose::ViewGraph;
    use cove_ui_compose::scene_core::{ComponentSourceLocation, Node, NodeTree, Recomposer};
    use diffuse_card_battle::support::battle_identifiers::BattlePlayerID;
    use diffuse_card_battle::support::battle_sample_factory::BattleSampleFactory;

    use super::*;

    fn contains_label(node: &Node, label: &str) -> bool {
        node.accessibility()
            .is_some_and(|semantics| semantics.label == label)
            || node
                .children()
                .iter()
                .any(|child| contains_label(child, label))
    }

    #[test]
    fn the_mounted_hud_recomposes_when_battle_state_changes() {
        let battle = BattleSampleFactory::make_three_kingdoms_duel();
        let mut snapshot = BattleHUDSnapshot::make(&battle, &BattlePlayerID::player()).unwrap();
        snapshot.hand = vec![BattleHandCardViewModel::new(
            "fixture", "Guard", 1, true, 0, 0, 3,
        )];
        snapshot.opponent_health = 12;
        snapshot.opponent_max_health = 18;
        let model = Rc::new(BattleHUDModel::new(snapshot.clone()));
        let tree = Rc::new(RefCell::new(NodeTree::new()));
        let recomposer = Rc::new(Recomposer::new());
        let graph = Rc::new(ViewGraph::new(tree.clone(), recomposer.clone()));
        graph.install(
            InGameBattleHUDView::new(model.clone()),
            ComponentSourceLocation::default(),
        );
        graph.compute_layout(900.0, 600.0);
        let has_label = |label| contains_label(&tree.borrow().root().unwrap(), label);
        assert!(has_label("12 / 18"));
        assert!(has_label("BLK 3"));
        assert!(has_label("Playable"));

        snapshot.opponent_health = 8;
        snapshot.hand[0].is_playable = false;
        model.update(snapshot);
        recomposer.commit_all();
        graph.compute_layout(900.0, 600.0);
        assert!(has_label("8 / 18"));
        assert!(has_label("Need energy"));
        assert!(!has_label("12 / 18"));
    }
}
