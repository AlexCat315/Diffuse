import GuavaUIRuntime
import GuavaUICompose
import CardBattleRuntime

/// In-game HUD overlay drawn on top of the 3D viewport.
///
/// Layout: opponent bar anchored to top-center; player status + hand + skills
/// anchored to the bottom. The root Box fills the whole viewport so flexbox
/// `justifyContent: .spaceBetween` pushes the two areas to opposite edges.
struct InGameBattleHUDView: View {
    private let model: BattleHUDModel

    // Stored as raw Observed<> to avoid "cannot use instance member within
    // property initializer" — Mirror still finds it and calls _wire().
    private var _snapshot: Observed<BattleHUDModel, BattleHUDSnapshot>

    var snapshot: BattleHUDSnapshot { _snapshot.wrappedValue }

    init(model: BattleHUDModel) {
        self.model = model
        self._snapshot = Observed(\.snapshot, on: model)
    }

    var body: some View {
        Box(direction: .column,
            alignItems: .center,
            justifyContent: .spaceBetween) {
            opponentBar
            Spacer()
            playerArea
        }
        .flex()
        .padding(horizontal: 20, vertical: 16)
    }

    // MARK: - Opponent bar (top center)

    private var opponentBar: some View {
        Box(direction: .column, alignItems: .center, spacing: 4) {
            Text("Opponent")
                .font(.label)
                .foregroundColor(Color(r: 0.8, g: 0.8, b: 0.85, a: 0.9))
            healthBar(current: snapshot.opponentHealth, max: snapshot.opponentMaxHealth,
                      fill: Color(r: 0.88, g: 0.28, b: 0.28, a: 1))
                .frame(width: 220, height: 8)
            Text("\(snapshot.opponentHealth) / \(snapshot.opponentMaxHealth)")
                .font(.caption)
                .foregroundColor(Color(r: 0.7, g: 0.7, b: 0.75, a: 0.85))
        }
        .padding(horizontal: 14, vertical: 10)
        .background(Color(r: 0.06, g: 0.07, b: 0.10, a: 0.78))
        .cornerRadius(10)
    }

    // MARK: - Player area (bottom)

    private var playerArea: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 10) {
            hand
            statusRow
        }
    }

    // MARK: - Hand cards
    // Returned as AnyView so buildArray can resolve [AnyView] for for-in.

    private var hand: some View {
        Row(alignment: .bottom, spacing: 10) {
            for card in snapshot.hand {
                handCardView(card)
            }
        }
    }

    private func handCardView(_ card: BattleHandCardViewModel) -> AnyView {
        AnyView(
            Box(direction: .column, alignItems: .stretch, spacing: 6) {
                Row(alignment: .center, spacing: 4) {
                    costBadge(card.cost, playable: card.isPlayable)
                    Spacer(minLength: 0)
                    Text(effectLabel(card))
                        .font(.label)
                        .foregroundColor(card.damage > 0
                            ? Color(r: 0.95, g: 0.55, b: 0.25, a: 1)
                            : Color(r: 0.35, g: 0.85, b: 0.55, a: 1))
                }
                Spacer(minLength: 0)
                Text(card.title)
                    .font(.bodyStrong)
                    .foregroundColor(card.isPlayable
                        ? Color(r: 0.95, g: 0.95, b: 0.98, a: 1)
                        : Color(r: 0.55, g: 0.55, b: 0.60, a: 1))
                Text(card.isPlayable ? "Playable" : "Need energy")
                    .font(.caption)
                    .foregroundColor(card.isPlayable
                        ? Color(r: 0.35, g: 0.85, b: 0.55, a: 1)
                        : Color(r: 0.50, g: 0.50, b: 0.55, a: 0.8))
            }
            .padding(10)
            .frame(width: 110, height: 156)
            .background(card.isPlayable
                ? Color(r: 0.12, g: 0.15, b: 0.22, a: 0.92)
                : Color(r: 0.08, g: 0.09, b: 0.13, a: 0.85))
            .cornerRadius(8)
            .border(card.isPlayable
                ? Color(r: 0.40, g: 0.55, b: 0.95, a: 0.85)
                : Color(r: 0.20, g: 0.22, b: 0.28, a: 0.6), width: 1)
        )
    }

    private func costBadge(_ cost: Int, playable: Bool) -> some View {
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            Text("\(cost)")
                .font(.bodyStrong)
                .foregroundColor(Color(r: 1, g: 1, b: 1, a: 1))
        }
        .frame(width: 22, height: 22)
        .background(playable
            ? Color(r: 0.35, g: 0.50, b: 0.95, a: 1)
            : Color(r: 0.25, g: 0.27, b: 0.33, a: 1))
        .cornerRadius(9999)
    }

    private func effectLabel(_ card: BattleHandCardViewModel) -> String {
        if card.damage  > 0 { return "ATK \(card.damage)"  }
        if card.healing > 0 { return "HEL \(card.healing)" }
        if card.block   > 0 { return "BLK \(card.block)"   }
        return "TACTIC"
    }

    // MARK: - Status row (player stats + skills + end turn)

    private var statusRow: some View {
        Row(alignment: .center, spacing: 12) {
            playerStats
            Spacer(minLength: 0)
            skillButtons
            Spacer(minLength: 0)
            endTurnButton
        }
        .padding(horizontal: 14, vertical: 10)
        .background(Color(r: 0.06, g: 0.07, b: 0.10, a: 0.80))
        .cornerRadius(10)
    }

    private var playerStats: some View {
        Box(direction: .column, alignItems: .flexStart, spacing: 6) {
            Row(alignment: .center, spacing: 8) {
                Text("HP")
                    .font(.label)
                    .foregroundColor(Color(r: 0.6, g: 0.6, b: 0.65, a: 1))
                    .frame(width: 30)
                healthBar(current: snapshot.health, max: snapshot.maxHealth,
                          fill: Color(r: 0.25, g: 0.80, b: 0.45, a: 1))
                    .frame(width: 140, height: 6)
                Text("\(snapshot.health)/\(snapshot.maxHealth)")
                    .font(.caption)
                    .foregroundColor(Color(r: 0.75, g: 0.75, b: 0.80, a: 1))
            }
            Row(alignment: .center, spacing: 8) {
                Text("EP")
                    .font(.label)
                    .foregroundColor(Color(r: 0.6, g: 0.6, b: 0.65, a: 1))
                    .frame(width: 30)
                energyPips
                Text("\(snapshot.energy)/\(snapshot.maxEnergy)")
                    .font(.caption)
                    .foregroundColor(Color(r: 0.75, g: 0.75, b: 0.80, a: 1))
            }
        }
    }

    private var energyPips: some View {
        Row(alignment: .center, spacing: 4) {
            for i in 0..<snapshot.maxEnergy {
                energyPip(i)
            }
        }
    }

    private func energyPip(_ i: Int) -> AnyView {
        AnyView(
            Box { EmptyView() }
                .frame(width: 12, height: 12)
                .background(i < snapshot.energy
                    ? Color(r: 0.40, g: 0.70, b: 0.98, a: 1)
                    : Color(r: 0.20, g: 0.22, b: 0.28, a: 1))
                .cornerRadius(9999)
        )
    }

    private var skillButtons: some View {
        Row(alignment: .center, spacing: 8) {
            for skill in snapshot.skills {
                skillButton(skill)
            }
        }
    }

    private func skillButton(_ skill: BattleSkillViewModel) -> AnyView {
        AnyView(
            Box(direction: .column, alignItems: .center, spacing: 3) {
                Box { EmptyView() }
                    .frame(width: 36, height: 36)
                    .background(skill.isEnabled
                        ? Color(r: 0.28, g: 0.40, b: 0.75, a: 0.90)
                        : Color(r: 0.15, g: 0.16, b: 0.20, a: 0.80))
                    .cornerRadius(8)
                    .border(skill.isEnabled
                        ? Color(r: 0.40, g: 0.55, b: 0.95, a: 0.70)
                        : Color(r: 0.22, g: 0.24, b: 0.30, a: 0.50), width: 1)
                Text(skill.isEnabled ? "Ready" : "CD \(skill.cooldownTurns)")
                    .font(.caption)
                    .foregroundColor(skill.isEnabled
                        ? Color(r: 0.65, g: 0.80, b: 1.0, a: 1)
                        : Color(r: 0.45, g: 0.45, b: 0.50, a: 1))
                Text(skill.title)
                    .font(.label)
                    .foregroundColor(Color(r: 0.70, g: 0.70, b: 0.75, a: 0.9))
            }
        )
    }

    private var endTurnButton: some View {
        Box(direction: .column, alignItems: .center, justifyContent: .center) {
            Text("END TURN")
                .font(.bodyStrong)
                .foregroundColor(Color(r: 0.95, g: 0.95, b: 1.0, a: 1))
        }
        .frame(width: 80, height: 48)
        .background(Color(r: 0.22, g: 0.35, b: 0.70, a: 0.92))
        .cornerRadius(10)
        .border(Color(r: 0.40, g: 0.55, b: 0.95, a: 0.70), width: 1)
    }

    // MARK: - Health bar

    private func healthBar(current: Int, max: Int, fill: Color) -> some View {
        Box(direction: .row, alignItems: .stretch) {
            Box { EmptyView() }
                .flex(Float(max > 0 ? current : 0))
                .background(fill)
            Box { EmptyView() }
                .flex(Float(max > 0 ? max - current : 1))
                .background(Color(r: 0.18, g: 0.20, b: 0.25, a: 0.85))
        }
        .cornerRadius(9999)
    }
}
