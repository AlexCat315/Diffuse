//! `CardBattleRuntimeTests` — Swift suite `CardBattleRuntime`.

use std::collections::BTreeMap;

use diffuse_card_battle::core::battle_reduction::{
    BattleCommandRejection, BattleEvent, BattleReductionResult,
};
use diffuse_card_battle::core::battle_state::{BattlePhase, BattlePlayerState, BattleState};
use diffuse_card_battle::core::battle_state_machine::BattleStateMachine;
use diffuse_card_battle::core::battle_state_validation::{
    BattleStateValidator, BattleValidationIssue,
};
use diffuse_card_battle::rules::battle_command::BattleCommand;
use diffuse_card_battle::rules::battle_content::{BattleCard, BattleSkill, BattleSkillTarget};
use diffuse_card_battle::rules::battle_effect::BattleCardEffect;
use diffuse_card_battle::rules::battle_rules::BattleRules;
use diffuse_card_battle::support::battle_hud_snapshot::{
    BattleHUDSnapshot, BattleHandCardViewModel, BattleSkillViewModel,
};
use diffuse_card_battle::support::battle_identifiers::BattlePlayerID;
use diffuse_card_battle::support::battle_sample_factory::BattleSampleFactory;

/// A player built from the Swift initialiser with every default spelled out.
#[allow(clippy::too_many_arguments)]
fn player(
    id: BattlePlayerID,
    health: i64,
    block: i64,
    max_energy: i64,
    energy: i64,
    deck: Vec<BattleCard>,
    hand: Vec<BattleCard>,
    skills: Vec<BattleSkill>,
) -> BattlePlayerState {
    BattlePlayerState::new(
        id,
        health,
        None,
        block,
        max_energy,
        energy,
        deck,
        hand,
        Vec::new(),
        skills,
    )
}

/// A state built from the Swift initialiser's argument order.
fn state(
    phase: BattlePhase,
    turn: i64,
    active_player_id: BattlePlayerID,
    players: Vec<BattlePlayerState>,
) -> BattleState {
    let mut map = BTreeMap::new();
    for player in players {
        map.insert(player.id.clone(), player);
    }
    BattleState::new(phase, turn, active_player_id, map, Vec::new())
}

// "starting player turn refreshes energy and draws into hand"
#[test]
fn start_player_turn_draws_cards() {
    let strike = BattleCard::new("strike", "Strike", 1, Some("slash".to_string()), 6, None);
    let guard_card = BattleCard::with_defaults("guard", "Guard", 1);
    let player_state = player(
        BattlePlayerID::player(),
        32,
        4,
        3,
        0,
        vec![strike, guard_card],
        Vec::new(),
        vec![BattleSkill::new(
            "slash",
            "Slash",
            0,
            BattleSkillTarget::Opponent,
        )],
    );
    let enemy = BattlePlayerState::with_defaults(BattlePlayerID::enemy(), 28, 2, Vec::new());
    let initial = BattleState::with_players(BTreeMap::from([
        (BattlePlayerID::player(), player_state),
        (BattlePlayerID::enemy(), enemy),
    ]));

    let next =
        BattleStateMachine::reduce(&initial, &BattleCommand::StartPlayerTurn { draw_count: 2 });

    assert_eq!(next.turn, 1);
    assert_eq!(next.phase, BattlePhase::Main);
    assert_eq!(next.active_player_id, BattlePlayerID::player());
    assert_eq!(next.players[&BattlePlayerID::player()].block, 0);
    assert_eq!(next.players[&BattlePlayerID::player()].energy, 3);
    assert_eq!(
        next.players[&BattlePlayerID::player()]
            .hand
            .iter()
            .map(|card| card.id.clone())
            .collect::<Vec<_>>(),
        vec!["strike", "guard"]
    );
    assert!(next.players[&BattlePlayerID::player()].deck.is_empty());
    assert_eq!(next.log, vec!["turn 1: player drew 2 card(s)"]);
}

// "starting turn reports actual drawn count when deck is short"
#[test]
fn start_player_turn_reports_actual_drawn_count() {
    let strike = BattleCard::new("strike", "Strike", 1, None, 6, None);
    let player_state =
        BattlePlayerState::with_defaults(BattlePlayerID::player(), 32, 3, vec![strike]);
    let initial =
        BattleState::with_players(BTreeMap::from([(BattlePlayerID::player(), player_state)]));

    let result = BattleStateMachine::reduce_with_result(
        &initial,
        &BattleCommand::StartPlayerTurn { draw_count: 3 },
    );

    assert_eq!(
        result.state.players[&BattlePlayerID::player()]
            .hand
            .iter()
            .map(|card| card.id.clone())
            .collect::<Vec<_>>(),
        vec!["strike"]
    );
    assert_eq!(result.state.log, vec!["turn 1: player drew 1 card(s)"]);
    assert_eq!(
        result.events,
        vec![BattleEvent::TurnStarted {
            turn: 1,
            player_id: BattlePlayerID::player(),
            cards_drawn: 1,
        }]
    );
}

// "starting a turn supports any battle player"
#[test]
fn start_turn_supports_any_player() {
    let enemy_card = BattleCard::new("counter", "Counter", 1, None, 4, None);
    let enemy = BattlePlayerState::with_defaults(BattlePlayerID::enemy(), 24, 2, vec![enemy_card]);
    let initial = BattleState::with_players(BTreeMap::from([(BattlePlayerID::enemy(), enemy)]));

    let result = BattleStateMachine::reduce_with_result(
        &initial,
        &BattleCommand::StartTurn {
            player_id: BattlePlayerID::enemy(),
            draw_count: 1,
        },
    );

    assert_eq!(result.state.turn, 1);
    assert_eq!(result.state.active_player_id, BattlePlayerID::enemy());
    assert_eq!(result.state.players[&BattlePlayerID::enemy()].energy, 2);
    assert_eq!(
        result.state.players[&BattlePlayerID::enemy()]
            .hand
            .iter()
            .map(|card| card.id.clone())
            .collect::<Vec<_>>(),
        vec!["counter"]
    );
    assert_eq!(
        result.events,
        vec![BattleEvent::TurnStarted {
            turn: 1,
            player_id: BattlePlayerID::enemy(),
            cards_drawn: 1,
        }]
    );
}

// "playing a card spends energy moves it to discard and damages target"
#[test]
fn play_card_resolves_damage() {
    let strike = BattleCard::new("strike", "Strike", 1, Some("slash".to_string()), 6, None);
    let player_state = player(
        BattlePlayerID::player(),
        32,
        0,
        3,
        2,
        Vec::new(),
        vec![strike],
        Vec::new(),
    );
    let enemy = BattlePlayerState::with_defaults(BattlePlayerID::enemy(), 6, 2, Vec::new());
    let initial = state(
        BattlePhase::Main,
        1,
        BattlePlayerID::player(),
        vec![player_state, enemy],
    );

    let next = BattleStateMachine::reduce(
        &initial,
        &BattleCommand::PlayCard {
            card_id: "strike".to_string(),
            target: BattlePlayerID::enemy(),
        },
    );

    assert_eq!(next.phase, BattlePhase::Victory);
    assert_eq!(next.players[&BattlePlayerID::player()].energy, 1);
    assert!(next.players[&BattlePlayerID::player()].hand.is_empty());
    assert_eq!(
        next.players[&BattlePlayerID::player()]
            .discard
            .iter()
            .map(|card| card.id.clone())
            .collect::<Vec<_>>(),
        vec!["strike"]
    );
    assert_eq!(next.players[&BattlePlayerID::enemy()].health, 0);
    assert_eq!(next.log, vec!["player played strike for 6 damage"]);
}

// "reducer exposes structured events and rejections"
#[test]
fn reducer_exposes_structured_result() {
    let finisher = BattleCard::new("finisher", "Finisher", 4, None, 18, None);
    let player_state = player(
        BattlePlayerID::player(),
        32,
        0,
        3,
        1,
        Vec::new(),
        vec![finisher],
        Vec::new(),
    );
    let enemy = BattlePlayerState::with_defaults(BattlePlayerID::enemy(), 24, 2, Vec::new());
    let initial = state(
        BattlePhase::Main,
        1,
        BattlePlayerID::player(),
        vec![player_state, enemy],
    );

    let result = BattleStateMachine::reduce_with_result(
        &initial,
        &BattleCommand::PlayCard {
            card_id: "finisher".to_string(),
            target: BattlePlayerID::enemy(),
        },
    );

    assert_eq!(result.state.players[&BattlePlayerID::player()].energy, 1);
    let expected = BattleCommandRejection::InsufficientEnergy {
        card_id: "finisher".to_string(),
        available: 1,
        required: 4,
    };
    assert_eq!(result.rejection, Some(expected.clone()));
    assert_eq!(
        result.events,
        vec![BattleEvent::CommandRejected {
            rejection: expected
        }]
    );
    assert_eq!(result.state.log, vec!["not enough energy for finisher"]);
}

// "battle commands are codable for replay and networking"
#[test]
fn battle_commands_are_codable() {
    let command = BattleCommand::PlayCard {
        card_id: "strike".to_string(),
        target: BattlePlayerID::enemy(),
    };

    let data = serde_json::to_string(&command).expect("encoding a battle command");
    let decoded: BattleCommand = serde_json::from_str(&data).expect("decoding a battle command");

    assert_eq!(decoded, command);
    // Swift's synthesized Codable shape (MIGRATION.md §5.4).
    assert_eq!(data, r#"{"playCard":{"cardID":"strike","target":"enemy"}}"#);
}

// "battle cards preserve legacy damage while exposing typed effects"
#[test]
fn battle_cards_expose_typed_effects() {
    let card = BattleCard::new("strike", "Strike", 1, None, 6, None);
    let encoded = serde_json::to_string(&card).expect("encoding a card");
    let decoded: BattleCard = serde_json::from_str(&encoded).expect("decoding a card");

    assert_eq!(card.effects, vec![BattleCardEffect::damage(6)]);
    assert_eq!(decoded.total_damage(), 6);
    assert_eq!(
        encoded,
        r#"{"id":"strike","title":"Strike","cost":1,"damage":6,"effects":[{"damage":{"_0":6}}]}"#
    );

    let legacy_json = r#"{"id":"old","title":"Old Strike","cost":1,"damage":5}"#;
    let legacy: BattleCard = serde_json::from_str(legacy_json).expect("decoding legacy JSON");
    assert_eq!(legacy.effects, vec![BattleCardEffect::damage(5)]);
    assert_eq!(legacy.total_damage(), 5);

    let guard_card = BattleCard::new(
        "guard",
        "Guard",
        1,
        None,
        0,
        Some(vec![BattleCardEffect::block(7)]),
    );
    assert_eq!(guard_card.total_block(), 7);
}

// "playing a healing card restores health up to max health"
#[test]
fn play_card_resolves_healing() {
    let heal = BattleCard::new(
        "heal",
        "Heal",
        1,
        None,
        0,
        Some(vec![BattleCardEffect::heal(10)]),
    );
    let player_state = BattlePlayerState::new(
        BattlePlayerID::player(),
        18,
        Some(24),
        0,
        3,
        2,
        Vec::new(),
        vec![heal],
        Vec::new(),
        Vec::new(),
    );
    let initial = state(
        BattlePhase::Main,
        1,
        BattlePlayerID::player(),
        vec![player_state],
    );

    let result = BattleStateMachine::reduce_with_result(
        &initial,
        &BattleCommand::PlayCard {
            card_id: "heal".to_string(),
            target: BattlePlayerID::player(),
        },
    );

    assert_eq!(result.state.phase, BattlePhase::Main);
    assert_eq!(result.state.players[&BattlePlayerID::player()].health, 24);
    assert_eq!(
        result.state.players[&BattlePlayerID::player()]
            .discard
            .iter()
            .map(|card| card.id.clone())
            .collect::<Vec<_>>(),
        vec!["heal"]
    );
    assert_eq!(
        result.events,
        vec![BattleEvent::HealthRestored {
            player_id: BattlePlayerID::player(),
            amount: 6,
        }]
    );
    assert_eq!(result.state.log, vec!["player played heal for 6 healing"]);
}

// "playing a block card adds block"
#[test]
fn play_card_resolves_block() {
    let guard_card = BattleCard::new(
        "guard",
        "Guard",
        1,
        None,
        0,
        Some(vec![BattleCardEffect::block(8)]),
    );
    let player_state = BattlePlayerState::new(
        BattlePlayerID::player(),
        18,
        Some(24),
        0,
        3,
        2,
        Vec::new(),
        vec![guard_card],
        Vec::new(),
        Vec::new(),
    );
    let initial = state(
        BattlePhase::Main,
        1,
        BattlePlayerID::player(),
        vec![player_state],
    );

    let result = BattleStateMachine::reduce_with_result(
        &initial,
        &BattleCommand::PlayCard {
            card_id: "guard".to_string(),
            target: BattlePlayerID::player(),
        },
    );

    assert_eq!(result.state.players[&BattlePlayerID::player()].block, 8);
    assert_eq!(
        result.events,
        vec![BattleEvent::BlockGained {
            player_id: BattlePlayerID::player(),
            amount: 8,
        }]
    );
    assert_eq!(result.state.log, vec!["player played guard for 8 block"]);
}

// "hud snapshot projects playable hand and skills for ui"
#[test]
fn hud_snapshot_projects_hand_and_skills() {
    let strike = BattleCard::new("strike", "Strike", 1, Some("slash".to_string()), 6, None);
    let finisher = BattleCard::new("finisher", "Finisher", 4, None, 18, None);
    let player_state = player(
        BattlePlayerID::player(),
        32,
        0,
        3,
        2,
        Vec::new(),
        vec![strike, finisher],
        vec![
            BattleSkill::new("slash", "Slash", 0, BattleSkillTarget::Opponent),
            BattleSkill::new("duel", "Duel", 2, BattleSkillTarget::Opponent),
        ],
    );
    let initial = state(
        BattlePhase::Main,
        2,
        BattlePlayerID::player(),
        vec![
            player_state,
            BattlePlayerState::with_defaults(BattlePlayerID::enemy(), 24, 2, Vec::new()),
        ],
    );

    let snapshot = BattleHUDSnapshot::make(&initial, &BattlePlayerID::player())
        .expect("snapshot for an existing player");

    assert_eq!(snapshot.phase, BattlePhase::Main);
    assert_eq!(snapshot.turn, 2);
    assert_eq!(snapshot.energy, 2);
    assert_eq!(snapshot.health, 32);
    assert_eq!(snapshot.max_health, 32);
    assert_eq!(snapshot.block, 0);
    assert_eq!(snapshot.opponent_health, 24);
    assert_eq!(snapshot.opponent_max_health, 24);
    assert_eq!(snapshot.opponent_block, 0);
    assert_eq!(snapshot.deck_count, 0);
    assert_eq!(snapshot.discard_count, 0);
    assert_eq!(
        snapshot
            .hand
            .iter()
            .map(|card| card.id.clone())
            .collect::<Vec<_>>(),
        vec!["strike", "finisher"]
    );
    assert_eq!(
        snapshot
            .hand
            .iter()
            .map(|card| card.is_playable)
            .collect::<Vec<_>>(),
        vec![true, false]
    );
    assert_eq!(
        snapshot.skills,
        vec![
            BattleSkillViewModel::new("slash", "Slash", 0, BattleSkillTarget::Opponent, true),
            BattleSkillViewModel::new("duel", "Duel", 2, BattleSkillTarget::Opponent, false),
        ]
    );
    assert_eq!(
        snapshot.hand[0],
        BattleHandCardViewModel::new("strike", "Strike", 1, true, 6, 0, 0)
    );
}

// "battle rules expose shared command availability"
#[test]
fn battle_rules_expose_command_availability() {
    let strike = BattleCard::new("strike", "Strike", 1, None, 6, None);
    let finisher = BattleCard::new("finisher", "Finisher", 4, None, 18, None);
    let player_state = player(
        BattlePlayerID::player(),
        32,
        0,
        3,
        2,
        Vec::new(),
        vec![strike.clone(), finisher.clone()],
        Vec::new(),
    );
    let enemy = BattlePlayerState::with_defaults(BattlePlayerID::enemy(), 24, 2, Vec::new());
    let initial = state(
        BattlePhase::Main,
        1,
        BattlePlayerID::player(),
        vec![player_state, enemy],
    );

    assert_eq!(
        BattleRules::opponent(&BattlePlayerID::player(), &initial),
        Some(BattlePlayerID::enemy())
    );
    assert!(BattleRules::can_play_cards(
        &initial,
        &BattlePlayerID::player()
    ));
    assert!(BattleRules::can_play(
        &strike,
        &BattlePlayerID::player(),
        &initial
    ));
    assert!(!BattleRules::can_play(
        &finisher,
        &BattlePlayerID::player(),
        &initial
    ));
    assert!(BattleRules::can_end_turn(
        &initial,
        &BattlePlayerID::player()
    ));
    assert!(!BattleRules::can_resolve_enemy_action(&initial));
}

// "ending player turn discards hand and passes control to enemy"
#[test]
fn end_player_turn_discards_hand() {
    let strike = BattleCard::new("strike", "Strike", 1, None, 6, None);
    let guard_card = BattleCard::with_defaults("guard", "Guard", 1);
    let player_state = player(
        BattlePlayerID::player(),
        32,
        0,
        3,
        2,
        Vec::new(),
        vec![strike, guard_card],
        Vec::new(),
    );
    let initial = state(
        BattlePhase::Main,
        2,
        BattlePlayerID::player(),
        vec![player_state],
    );

    let next = BattleStateMachine::reduce(&initial, &BattleCommand::EndPlayerTurn {});

    assert_eq!(next.phase, BattlePhase::EnemyTurn);
    assert_eq!(next.active_player_id, BattlePlayerID::enemy());
    assert_eq!(next.players[&BattlePlayerID::player()].energy, 0);
    assert!(next.players[&BattlePlayerID::player()].hand.is_empty());
    assert_eq!(
        next.players[&BattlePlayerID::player()]
            .discard
            .iter()
            .map(|card| card.id.clone())
            .collect::<Vec<_>>(),
        vec!["strike", "guard"]
    );
    assert_eq!(next.log, vec!["turn 2: player ended turn"]);
}

// "ending a turn supports any battle player"
#[test]
fn end_turn_supports_any_player() {
    let enemy_card = BattleCard::new("counter", "Counter", 1, None, 4, None);
    let enemy = player(
        BattlePlayerID::enemy(),
        24,
        0,
        2,
        1,
        Vec::new(),
        vec![enemy_card],
        Vec::new(),
    );
    let player_state =
        BattlePlayerState::with_defaults(BattlePlayerID::player(), 32, 3, Vec::new());
    let initial = state(
        BattlePhase::Main,
        3,
        BattlePlayerID::enemy(),
        vec![player_state, enemy],
    );

    let result = BattleStateMachine::reduce_with_result(
        &initial,
        &BattleCommand::EndTurn {
            player_id: BattlePlayerID::enemy(),
        },
    );

    assert_eq!(result.state.phase, BattlePhase::Draw);
    assert_eq!(result.state.active_player_id, BattlePlayerID::player());
    assert_eq!(result.state.players[&BattlePlayerID::enemy()].energy, 0);
    assert!(
        result.state.players[&BattlePlayerID::enemy()]
            .hand
            .is_empty()
    );
    assert_eq!(
        result.state.players[&BattlePlayerID::enemy()]
            .discard
            .iter()
            .map(|card| card.id.clone())
            .collect::<Vec<_>>(),
        vec!["counter"]
    );
    assert_eq!(
        result.events,
        vec![BattleEvent::TurnEnded {
            turn: 3,
            player_id: BattlePlayerID::enemy(),
        }]
    );
}

// "enemy action damages player and returns to player draw phase"
#[test]
fn enemy_action_returns_to_player_draw() {
    let player_state =
        BattlePlayerState::with_defaults(BattlePlayerID::player(), 32, 3, Vec::new());
    let enemy = BattlePlayerState::with_defaults(BattlePlayerID::enemy(), 24, 2, Vec::new());
    let initial = state(
        BattlePhase::EnemyTurn,
        2,
        BattlePlayerID::enemy(),
        vec![player_state, enemy],
    );

    let next =
        BattleStateMachine::reduce(&initial, &BattleCommand::ResolveEnemyAction { damage: 5 });

    assert_eq!(next.phase, BattlePhase::Draw);
    assert_eq!(next.active_player_id, BattlePlayerID::player());
    assert_eq!(next.players[&BattlePlayerID::player()].health, 27);
    assert_eq!(next.log, vec!["enemy dealt 5 damage"]);
}

// "block absorbs incoming damage"
#[test]
fn block_absorbs_incoming_damage() {
    let player_state = player(
        BattlePlayerID::player(),
        32,
        3,
        3,
        0,
        Vec::new(),
        Vec::new(),
        Vec::new(),
    );
    let enemy = BattlePlayerState::with_defaults(BattlePlayerID::enemy(), 24, 2, Vec::new());
    let initial = state(
        BattlePhase::EnemyTurn,
        2,
        BattlePlayerID::enemy(),
        vec![player_state, enemy],
    );

    let next =
        BattleStateMachine::reduce(&initial, &BattleCommand::ResolveEnemyAction { damage: 5 });

    assert_eq!(next.players[&BattlePlayerID::player()].health, 30);
    assert_eq!(next.players[&BattlePlayerID::player()].block, 0);
    assert_eq!(next.log, vec!["enemy dealt 2 damage (3 blocked)"]);
}

// "sample factory creates playable duel state"
#[test]
fn sample_factory_creates_duel() {
    let initial = BattleSampleFactory::make_three_kingdoms_duel();
    let turn =
        BattleStateMachine::reduce(&initial, &BattleCommand::StartPlayerTurn { draw_count: 3 });
    let snapshot = BattleHUDSnapshot::make(&turn, &BattlePlayerID::player());

    assert_eq!(initial.players[&BattlePlayerID::player()].deck.len(), 4);
    assert_eq!(
        initial.players[&BattlePlayerID::player()]
            .deck
            .last()
            .expect("the deck has a last card")
            .total_block(),
        6
    );
    assert_eq!(initial.players[&BattlePlayerID::enemy()].health, 32_000);
    let snapshot = snapshot.expect("snapshot for the sample player");
    assert_eq!(snapshot.hand.len(), 3);
    assert_eq!(
        snapshot
            .skills
            .iter()
            .map(|skill| skill.id.clone())
            .collect::<Vec<_>>(),
        vec!["slash", "rally", "duel"]
    );
}

// "state validator reports invalid battle data"
#[test]
fn validator_reports_invalid_battle_data() {
    let bad_card = BattleCard::new("bad-card", "Bad Card", -1, None, -4, None);
    let player_state = BattlePlayerState::new(
        BattlePlayerID::enemy(),
        -10,
        Some(2),
        -3,
        2,
        3,
        vec![bad_card],
        Vec::new(),
        Vec::new(),
        vec![BattleSkill::new(
            "bad-skill",
            "Bad Skill",
            -1,
            BattleSkillTarget::Opponent,
        )],
    );
    let initial = state(
        BattlePhase::Setup,
        0,
        BattlePlayerID::player(),
        vec![player_state],
    );

    let issues = BattleStateValidator::validate(&initial);

    assert!(
        issues.contains(&BattleValidationIssue::MissingActivePlayer {
            player_id: BattlePlayerID::player(),
        })
    );
    assert!(
        !issues.contains(&BattleValidationIssue::MismatchedPlayerKey {
            expected: BattlePlayerID::enemy(),
            actual: BattlePlayerID::enemy(),
        })
    );
    assert!(issues.contains(&BattleValidationIssue::NegativeHealth {
        player_id: BattlePlayerID::enemy(),
        health: -10,
    }));
    assert!(issues.contains(&BattleValidationIssue::NegativeBlock {
        player_id: BattlePlayerID::enemy(),
        block: -3,
    }));
    assert!(
        issues.contains(&BattleValidationIssue::EnergyExceedsMaximum {
            player_id: BattlePlayerID::enemy(),
            energy: 3,
            max_energy: 2,
        })
    );
    assert!(issues.contains(&BattleValidationIssue::NegativeCardCost {
        player_id: BattlePlayerID::enemy(),
        card_id: "bad-card".to_string(),
        cost: -1,
    }));
    assert!(issues.contains(&BattleValidationIssue::NegativeCardDamage {
        player_id: BattlePlayerID::enemy(),
        card_id: "bad-card".to_string(),
        damage: -4,
    }));
    assert!(
        issues.contains(&BattleValidationIssue::NegativeSkillCooldown {
            player_id: BattlePlayerID::enemy(),
            skill_id: "bad-skill".to_string(),
            cooldown_turns: -1,
        })
    );
}

// "player state decodes legacy max health"
#[test]
fn player_state_decodes_legacy_max_health() {
    let json = r#"{"id":"player","health":12,"maxEnergy":3,"deck":[]}"#;
    let player_state: BattlePlayerState = serde_json::from_str(json).expect("decoding legacy JSON");

    assert_eq!(player_state.health, 12);
    assert_eq!(player_state.max_health, 12);
    assert_eq!(player_state.block, 0);
    assert_eq!(player_state.energy, 0);
}

// The encoded `players` dictionary is Swift's alternating key/value array.
#[test]
fn battle_state_round_trips_swift_dictionary_shape() {
    let initial = BattleSampleFactory::make_three_kingdoms_duel();
    let encoded = serde_json::to_string(&initial).expect("encoding a battle state");
    assert!(
        encoded.contains(r#""players":["enemy","#),
        "players must encode as an alternating array: {encoded}"
    );
    let decoded: BattleState = serde_json::from_str(&encoded).expect("decoding a battle state");
    assert_eq!(decoded, initial);

    let reduction = BattleReductionResult::with_state(initial);
    let encoded = serde_json::to_string(&reduction).expect("encoding a reduction result");
    assert!(!encoded.contains("rejection"));
    let decoded: BattleReductionResult =
        serde_json::from_str(&encoded).expect("decoding a reduction result");
    assert_eq!(decoded.rejection, None);
}

// Decoding the exact payloads Swift's sorted-key `JSONEncoder` produced
// (captured from the Swift sources this crate translates).
#[test]
fn decodes_swift_encoded_payloads() {
    let command: BattleCommand =
        serde_json::from_str(r#"{"startTurn":{"drawCount":1,"playerID":"enemy"}}"#)
            .expect("decoding a Swift startTurn command");
    assert_eq!(
        command,
        BattleCommand::StartTurn {
            player_id: BattlePlayerID::enemy(),
            draw_count: 1,
        }
    );
    let command: BattleCommand = serde_json::from_str(r#"{"endPlayerTurn":{}}"#)
        .expect("decoding a Swift endPlayerTurn command");
    assert_eq!(command, BattleCommand::EndPlayerTurn {});

    let event: BattleEvent =
        serde_json::from_str(r#"{"turnStarted":{"cardsDrawn":2,"playerID":"player","turn":1}}"#)
            .expect("decoding a Swift turnStarted event");
    assert_eq!(
        event,
        BattleEvent::TurnStarted {
            turn: 1,
            player_id: BattlePlayerID::player(),
            cards_drawn: 2,
        }
    );
    let event: BattleEvent = serde_json::from_str(r#"{"playerDefeated":{"_0":"player"}}"#)
        .expect("decoding a Swift playerDefeated event");
    assert_eq!(
        event,
        BattleEvent::PlayerDefeated {
            player_id: BattlePlayerID::player(),
        }
    );

    let issue: BattleValidationIssue = serde_json::from_str(
        r#"{"negativeSkillCooldown":{"cooldownTurns":-1,"playerID":"enemy","skillID":"s"}}"#,
    )
    .expect("decoding a Swift validation issue");
    assert_eq!(
        issue,
        BattleValidationIssue::NegativeSkillCooldown {
            player_id: BattlePlayerID::enemy(),
            skill_id: "s".to_string(),
            cooldown_turns: -1,
        }
    );

    let skill: BattleSkill = serde_json::from_str(
        r#"{"cooldownTurns":0,"id":"slash","target":"opponent","title":"Slash"}"#,
    )
    .expect("decoding a Swift skill");
    assert_eq!(
        skill,
        BattleSkill::new("slash", "Slash", 0, BattleSkillTarget::Opponent)
    );
}

// Byte-level parity with Swift `JSONEncoder` using `.sortedKeys` — the only
// deterministic output Swift can produce, since its default key order varies per
// process. The expected strings were captured from the Swift sources.
#[test]
fn sorted_key_encoding_matches_swift_bytes() {
    let skill = BattleSkill::new("slash", "Slash", 0, BattleSkillTarget::Opponent);
    let encoded = serde_json::to_value(&skill).expect("encoding a skill");
    assert_eq!(
        serde_json::to_string(&encoded).expect("re-encoding a skill"),
        r#"{"cooldownTurns":0,"id":"slash","target":"opponent","title":"Slash"}"#
    );

    let card = BattleCard::new("old", "Old Strike", 1, None, 5, None);
    assert_eq!(
        serde_json::to_string(&serde_json::to_value(&card).expect("encoding a card"))
            .expect("re-encoding a card"),
        r#"{"cost":1,"damage":5,"effects":[{"damage":{"_0":5}}],"id":"old","title":"Old Strike"}"#
    );

    let command = BattleCommand::StartTurn {
        player_id: BattlePlayerID::enemy(),
        draw_count: 1,
    };
    assert_eq!(
        serde_json::to_string(&serde_json::to_value(&command).expect("encoding a command"))
            .expect("re-encoding a command"),
        r#"{"startTurn":{"drawCount":1,"playerID":"enemy"}}"#
    );

    let state = BattleState::with_players(BTreeMap::from([(
        BattlePlayerID::player(),
        BattlePlayerState::with_defaults(BattlePlayerID::player(), 12, 3, Vec::new()),
    )]));
    assert_eq!(
        serde_json::to_string(&serde_json::to_value(&state).expect("encoding a state"))
            .expect("re-encoding a state"),
        concat!(
            r#"{"activePlayerID":"player","log":[],"phase":"setup","players":["player","#,
            r#"{"block":0,"deck":[],"discard":[],"energy":0,"hand":[],"health":12,"id":"player","#,
            r#""maxEnergy":3,"maxHealth":12,"skills":[]}],"turn":0}"#
        )
    );
}

// Decoding a Swift `.sortedKeys` state and re-encoding it reproduces the bytes.
#[test]
fn sorted_key_round_trip_is_byte_identical() {
    let swift_bytes = concat!(
        r#"{"activePlayerID":"player","log":[],"phase":"setup","players":["player","#,
        r#"{"block":0,"deck":[],"discard":[],"energy":0,"hand":[],"health":12,"id":"player","#,
        r#""maxEnergy":3,"maxHealth":12,"skills":[]}],"turn":0}"#
    );
    let decoded: BattleState = serde_json::from_str(swift_bytes).expect("decoding Swift bytes");
    let reencoded = serde_json::to_string(
        &serde_json::to_value(&decoded).expect("normalising the decoded state"),
    )
    .expect("re-encoding the decoded state");
    assert_eq!(reencoded, swift_bytes);
}
