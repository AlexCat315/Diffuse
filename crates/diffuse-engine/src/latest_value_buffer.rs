//! Translation of Engine/Sources/EngineCore/LatestValueBuffer.swift.
//!
//! Single-producer / single-consumer handoff that keeps only the newest value.
//!
//! This is a latest-wins mailbox, not a FIFO queue: `publish` never blocks and
//! `consume_latest` returns the most recently published value, dropping anything
//! the consumer did not pick up in between. The handoff stays bounded to a small
//! slot count (three by default) so producer and consumer never allocate in the
//! hot path. Slot selection is coordinated under one short critical section.

use std::sync::Mutex;

use crate::locked_state::LockedState;

#[derive(Default)]
struct BufferState {
    published_index: i64,
    published_sequence: u64,
    consumed_sequence: u64,
    consumer_index: i64,
    producer_cursor: usize,
}

struct Slot<Value> {
    value: Mutex<Option<Value>>,
}

impl<Value: Clone> Slot<Value> {
    fn write(&self, new_value: Value) {
        *self
            .value
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(new_value);
    }

    fn read(&self) -> Option<Value> {
        self.value
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }
}

pub struct LatestValueBuffer<Value: Send> {
    slots: Vec<Slot<Value>>,
    state: LockedState<BufferState>,
}

impl<Value: Send + Clone> LatestValueBuffer<Value> {
    /// Swift's `init(slotCount:)` defaults to three slots and traps on fewer.
    pub fn new(slot_count: usize) -> Self {
        assert!(
            slot_count >= 3,
            "LatestValueBuffer requires at least three slots"
        );
        let slots = (0..slot_count)
            .map(|_| Slot {
                value: Mutex::new(None),
            })
            .collect();
        LatestValueBuffer {
            slots,
            state: LockedState::new(BufferState::default()),
        }
    }

    pub fn with_default_capacity() -> Self {
        Self::new(3)
    }

    pub fn slot_count(&self) -> usize {
        self.slots.len()
    }

    pub fn publish(&self, value: Value) {
        let slot_count = self.slots.len();
        let candidate = self.state.with_lock(|state| {
            let mut slot_index = state.producer_cursor;
            for _ in 0..slot_count {
                if slot_index as i64 != state.consumer_index
                    && slot_index as i64 != state.published_index
                {
                    break;
                }
                slot_index = (slot_index + 1) % slot_count;
            }
            state.producer_cursor = (slot_index + 1) % slot_count;
            slot_index
        });

        self.slots[candidate].write(value);
        self.state.with_lock(|state| {
            state.published_index = candidate as i64;
            state.published_sequence = state.published_sequence.wrapping_add(1);
        });
    }

    pub fn consume_latest(&self) -> Option<Value> {
        let slot_index = self.state.with_lock(|state| -> Option<usize> {
            if state.published_sequence == state.consumed_sequence {
                return None;
            }
            if state.published_index < 0 || state.published_index as usize >= self.slots.len() {
                return None;
            }
            state.consumer_index = state.published_index;
            state.consumed_sequence = state.published_sequence;
            Some(state.published_index as usize)
        })?;
        self.slots[slot_index].read()
    }
}
