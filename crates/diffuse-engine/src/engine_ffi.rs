//! Translation of Engine/Sources/EngineCore/EngineFFI.swift and the C stub it
//! called (`Engine/Sources/Bridge/CEngineBridge/engine_bridge.c`).
//!
//! Swift forwarded every frame phase to `CEngineBridge`'s C globals. The Rust
//! port keeps that process-wide state machine in Rust: initialization and phase
//! ordering are validated, invalid calls log a warning instead of panicking, and
//! every transition is observable through the bridge's counters.

use cove_logging::{Level, LogEvent, LogSystem};
use diffuse_kernel::input_event::InputEvent;

use crate::engine_core::EngineRuntime;
use crate::locked_state::LockedState;

const LOG_TARGET: &str = "com.cove.engine.bridge";

#[derive(Default)]
struct BridgeState {
    initialized: bool,
    input_frame_count: u64,
    sim_frame_count: u64,
    prepared_frame_count: u64,
    submitted_frame_count: u64,
    total_simulated_seconds: f64,
    last_delta_time: f64,
}

fn bridge_state() -> &'static LockedState<BridgeState> {
    static STATE: std::sync::OnceLock<LockedState<BridgeState>> = std::sync::OnceLock::new();
    STATE.get_or_init(|| LockedState::new(BridgeState::default()))
}

fn log(level: Level, message: String) {
    LogSystem::logger(LOG_TARGET).log(&LogEvent::new(level, message));
}

fn sanitize_delta_time(delta_time: f64) -> f64 {
    if !delta_time.is_finite() || delta_time <= 0.0 {
        return 1.0 / 60.0;
    }
    if delta_time > 0.25 {
        return 0.25;
    }
    delta_time
}

fn ensure_initialized(state: &BridgeState, function_name: &str) -> bool {
    if state.initialized {
        return true;
    }
    log(
        Level::Warning,
        format!("[CEngineBridge] {function_name} ignored: runtime is not initialized"),
    );
    false
}

fn should_emit_log(frame_count: u64) -> bool {
    frame_count == 0 || (frame_count + 1).is_multiple_of(120)
}

/// `BridgedEngineRuntime` — the frame validator the C bridge provided.
#[derive(Default)]
pub struct BridgedEngineRuntime {
    _private: (),
}

impl BridgedEngineRuntime {
    pub fn new() -> Self {
        BridgedEngineRuntime { _private: () }
    }
}

impl EngineRuntime for BridgedEngineRuntime {
    fn initialize(&self) {
        bridge_state().with_lock(|state| {
            if state.initialized {
                log(
                    Level::Warning,
                    "[CEngineBridge] init called twice; keeping existing runtime".to_string(),
                );
                return;
            }
            state.initialized = true;
            log(
                Level::Debug,
                "[CEngineBridge] init: runtime ready".to_string(),
            );
        });
    }

    fn tick_input(&self, delta_time: f64, _input_events: &[InputEvent]) {
        bridge_state().with_lock(|state| {
            if !ensure_initialized(state, "engine_tick_input") {
                return;
            }
            if state.input_frame_count != state.sim_frame_count {
                log(
                    Level::Warning,
                    format!(
                        "[CEngineBridge] engine_tick_input ignored: input={} sim={}",
                        state.input_frame_count, state.sim_frame_count
                    ),
                );
                return;
            }
            state.last_delta_time = sanitize_delta_time(delta_time);
            state.input_frame_count += 1;
        });
    }

    fn tick_simulation(&self, delta_time: f64) {
        bridge_state().with_lock(|state| {
            if !ensure_initialized(state, "engine_tick_sim") {
                return;
            }
            if state.input_frame_count <= state.sim_frame_count {
                log(
                    Level::Warning,
                    format!(
                        "[CEngineBridge] engine_tick_sim ignored: input={} sim={}",
                        state.input_frame_count, state.sim_frame_count
                    ),
                );
                return;
            }
            state.last_delta_time = sanitize_delta_time(delta_time);
            state.total_simulated_seconds += state.last_delta_time;
            state.sim_frame_count += 1;
        });
    }

    fn tick_render_prepare(&self, delta_time: f64) {
        bridge_state().with_lock(|state| {
            if !ensure_initialized(state, "engine_tick_render_prepare") {
                return;
            }
            if state.sim_frame_count <= state.prepared_frame_count {
                log(
                    Level::Warning,
                    format!(
                        "[CEngineBridge] engine_tick_render_prepare ignored: sim={} prepared={}",
                        state.sim_frame_count, state.prepared_frame_count
                    ),
                );
                return;
            }
            state.last_delta_time = sanitize_delta_time(delta_time);
            if should_emit_log(state.prepared_frame_count) {
                log(
                    Level::Debug,
                    format!(
                        "[CEngineBridge] prepare frame={}",
                        state.prepared_frame_count
                    ),
                );
            }
            state.prepared_frame_count += 1;
        });
    }

    fn tick_render_submit(&self, delta_time: f64) {
        bridge_state().with_lock(|state| {
            if !ensure_initialized(state, "engine_tick_render_submit") {
                return;
            }
            if state.prepared_frame_count <= state.submitted_frame_count {
                log(
                    Level::Warning,
                    format!(
                        "[CEngineBridge] engine_tick_render_submit ignored: prepared={} submitted={}",
                        state.prepared_frame_count, state.submitted_frame_count
                    ),
                );
                return;
            }
            state.last_delta_time = sanitize_delta_time(delta_time);
            if should_emit_log(state.submitted_frame_count) {
                log(
                    Level::Debug,
                    format!(
                        "[CEngineBridge] submit frame={}",
                        state.submitted_frame_count
                    ),
                );
            }
            state.submitted_frame_count += 1;
        });
    }

    fn shutdown(&self) {
        bridge_state().with_lock(|state| {
            if !state.initialized {
                log(
                    Level::Warning,
                    "[CEngineBridge] shutdown ignored: runtime is not initialized".to_string(),
                );
                return;
            }
            log(
                Level::Debug,
                format!(
                    "[CEngineBridge] shutdown: input={} sim={} prepared={} submitted={} simulated={:.3}s",
                    state.input_frame_count,
                    state.sim_frame_count,
                    state.prepared_frame_count,
                    state.submitted_frame_count,
                    state.total_simulated_seconds
                ),
            );
            *state = BridgeState::default();
        });
    }
}

/// The bridge's cross-thread state is process-wide; `Mutex` inside
/// `LockedState` makes the runtime `Sync` for `EngineHost`.
const _: fn() = || {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<BridgedEngineRuntime>();
};
