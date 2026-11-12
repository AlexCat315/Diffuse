//! Translation of Editor/Sources/EditorUI/HUD/BattleHUDModel.swift.

use std::cell::RefCell;
use std::rc::Rc;

use cove_ui_compose::scene_core::{ObservableObject, ObservablePublisher};
use diffuse_card_battle::support::battle_hud_snapshot::BattleHUDSnapshot;

/// Main-thread observable model that bridges `BattleHUDSnapshot` to the CoveUI
/// reactive system. Observers are notified synchronously on `update`.
pub struct BattleHUDModel {
    snapshot: RefCell<BattleHUDSnapshot>,
    publisher: ObservablePublisher,
}

impl BattleHUDModel {
    pub fn new(snapshot: BattleHUDSnapshot) -> Self {
        BattleHUDModel {
            snapshot: RefCell::new(snapshot),
            publisher: ObservablePublisher::default(),
        }
    }

    pub fn snapshot(&self) -> BattleHUDSnapshot {
        self.snapshot.borrow().clone()
    }

    pub fn update(&self, snapshot: BattleHUDSnapshot) {
        *self.snapshot.borrow_mut() = snapshot;
        self.publisher.send();
    }
}

impl ObservableObject for BattleHUDModel {
    fn register_observer(&self, handler: Rc<dyn Fn()>) -> u64 {
        self.publisher.register_observer(handler)
    }

    fn unregister_observer(&self, token: u64) {
        self.publisher.unregister_observer(token);
    }
}
